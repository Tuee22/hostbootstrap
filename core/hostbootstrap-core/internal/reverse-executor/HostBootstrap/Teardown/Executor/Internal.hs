{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Storeless reverse-plan admission for a child executor.

This module owns no durable authority. It reconstructs the exact reverse
projection from the locally admitted plan and accepts an adapter only when
that projection renders byte-for-byte to the authenticated wire.
-}
module HostBootstrap.Teardown.Executor.Internal (
    withStorelessReverseExecutorKernel,
    runStorelessReversePreparedKernel,
    withStorelessReverseDescentResultKernel,
    failedUpExpectedOperations,
)
where

import Control.Exception.Safe (displayException, tryAny)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (nub)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority (ProjectVerb (ProjectDestroy, ProjectDown, ProjectUp), projectVerbName)
import HostBootstrap.Teardown.Preparation (renderReverseAdapterKernel)
import HostBootstrap.Handoff (handoffErrorMessage, takeHandoffFrame)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Prepared (PreparedGate, preparedGateAttempt, preparedGateFence, preparedGateJournalVersion, preparedGateOperation, preparedGateSession)
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    forward,
    operationKeyText,
    plannedStepFrameId,
    plannedStepOperationKey,
    plannedStepProjectedOperationKeys,
    renderSnapshot,
    stablePlanSnapshotDigest,
    topology,
    topologyFrameOrder,
    topologyParentEdges,
 )
import HostBootstrap.ProjectPlan.Frame (CurrentFrame, currentFrameId)
import HostBootstrap.Teardown (
    LocalWork,
    SubtreeSettled,
    TeardownError (TeardownReverseDescentRefused, TeardownTerminalObservationsMismatch),
    TeardownForest,
    TeardownOutcome (TeardownFailed, TeardownForeignRetained, TeardownRefused, TeardownReleased),
    TeardownPlan,
    attemptLocalWork,
    attemptPreDescentStep,
    descentWorkChildFrame,
    eliminateTeardownProgress,
    eliminateTeardownWork,
    failedUpTeardownPlanKernel,
    localWorkAction,
    localWorkKey,
    localWorkRun,
    nextTeardownWork,
    openTeardownForest,
    renderTeardownObservations,
    settleDescentWork,
    teardownForestOutstanding,
    teardownObservationsFromWire,
    teardownPlan,
    verifySubtreeSettled,
    withDescentWorkSubtree,
    withTeardownAuthorization,
 )

-- | Admit only the canonical adapter for this exact local reverse projection.
withStorelessReverseExecutorKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId frame ->
    ProjectVerb verb ->
    ByteString ->
    (TeardownPlan scope planId frame verb -> result) ->
    Either TeardownError result
withStorelessReverseExecutorKernel plan current verb observed use =
    case verb of
        ProjectUp -> do
            expected <- failedUpExpectedOperations observed
            let ordered = filter (`elem` expected) admittedForwardOperations
            if length expected /= length (nub expected) || length ordered /= length expected
                then Left (refusal "the failed-Up adapter names duplicate or unadmitted operations")
                else pure ()
            projection <- failedUpTeardownPlanKernel plan current ordered
            verify projection
        ProjectDown -> verify (teardownPlan plan current verb)
        ProjectDestroy -> verify (teardownPlan plan current verb)
  where
    verify projection = case parentFrames of
        [parent] -> case openTeardownForest projection of
            Left failure -> Left failure
            Right forest
                | length expected /= length (nub expected) ->
                    Left (refusal "the reverse child operation order contains duplicates")
                | observed /= canonical ->
                    Left (refusal "the supplied reverse child adapter is not canonical")
                | otherwise -> Right (use projection)
              where
                expected = teardownForestOutstanding forest
                canonical = renderReverseAdapterKernel planDigest (projectVerbName verb) parent child expected
        _ -> Left (refusal "the reverse child frame is not one exact topology child")
    child = currentFrameId current
    admittedFrames = dropWhile (/= child) (map fst (NonEmpty.toList (topologyFrameOrder (topology plan))))
    admittedForwardOperations =
        [ operation
        | frame <- admittedFrames
        , step <- NonEmpty.toList (forward plan)
        , plannedStepFrameId step == frame
        , operation <-
            Text.pack (operationKeyText (plannedStepOperationKey step))
                : map (Text.pack . operationKeyText) (plannedStepProjectedOperationKeys step)
        ]
    parentFrames =
        [parent | (parent, edgeChild) <- topologyParentEdges (topology plan), edgeChild == child]
    planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
    refusal = TeardownReverseDescentRefused

failedUpExpectedOperations :: ByteString -> Either TeardownError [Text]
failedUpExpectedOperations raw = do
    frames <- collect raw
    case frames of
        domain : version : _digest : _parent : _child : verb : phase : countBytes : rest
            | domain == "hostbootstrap/reverse-descent-adapter"
                && version == wordBytes 1
                && verb == "up"
                && phase == "teardown" -> do
                count <- decodeWord countBytes
                let (operations, suffix) = splitAt (fromIntegral count) rest
                if suffix /= [wordBytes 3, "released", "foreign-retained", "refused"]
                    then Left (refusal "the failed-Up adapter suffix differs")
                    else traverse decode operations
        _ -> Left (refusal "the failed-Up adapter header differs")
  where
    collect bytes
        | ByteString.null bytes = Right []
        | otherwise = case takeHandoffFrame bytes of
            Left failure -> Left (refusal (Text.pack (handoffErrorMessage failure)))
            Right (frame, trailing) -> (frame :) <$> collect trailing
    decode bytes = case TextEncoding.decodeUtf8' bytes of
        Left _ -> Left (refusal "the failed-Up adapter operation is not UTF-8")
        Right value -> Right value
    decodeWord bytes
        | ByteString.length bytes /= 8 = Left (refusal "the failed-Up adapter count is not a word")
        | otherwise = Right (ByteString.foldl' (\value byte -> value * 256 + fromIntegral byte) 0 bytes :: Word64)
    refusal = TeardownReverseDescentRefused

wordBytes :: Word64 -> ByteString
wordBytes = LazyByteString.toStrict . Builder.toLazyByteString . Builder.word64BE

-- | Run only the exact local work named by one verified Prepared response.
runStorelessReversePreparedKernel ::
    HostConfig ->
    (PreparedGate -> LocalWork scope planId frame verb -> IO TeardownOutcome) ->
    (ByteString -> Either Text ByteString) ->
    TeardownForest scope planId frame verb ->
    PreparedGate ->
    Text ->
    IO (Either TeardownError (TeardownForest scope planId frame verb, ByteString))
runStorelessReversePreparedKernel host runCoreManaged wrapObservation forest gate operation
    | preparedGateOperation gate /= operation = pure (Left (refusal "the gate names another reverse operation"))
    | Text.null (preparedGateSession gate) || preparedGateFence gate == 0 || preparedGateAttempt gate == 0 || preparedGateJournalVersion gate == 0 =
        pure (Left (refusal "the reverse gate is missing durable authority"))
    | otherwise =
        eliminateTeardownProgress
            (nextTeardownWork forest)
            (const (pure (Left (refusal "the reverse frame is already complete"))))
            ( \point ->
            withTeardownAuthorization
                point
                (const (pure (Left (refusal "a pre-descent reachability step is root-owned"))))
                ( \_ work ->
                    eliminateTeardownWork
                        work
                        runLocal
                        (const (pure (Left (refusal "a Descend response is required for child work"))))
                )
        )
  where
    runLocal local
        | localWorkKey local /= operation =
            pure (Left (refusal "the Prepared response names another reverse operation"))
        | otherwise = case traverse check templates of
            Left failure -> pure (Left failure)
            Right _ -> do
                attempted <- tryAny $ case localWorkRun local of
                    Nothing -> runCoreManaged gate local
                    Just run -> run host (localWorkAction local)
                let outcome = either (TeardownFailed . displayException) id attempted
                pure $ do
                    normalized <- normalizeReverseOutcome operation wrapObservation outcome
                    observation <- renderTeardownObservations [(operation, normalized)]
                    Right (attemptLocalWork local normalized, observation)
    refusal = TeardownReverseDescentRefused
    templates = [TeardownReleased, TeardownForeignRetained placeholder, TeardownRefused placeholder, TeardownFailed placeholder]
    check template = do
        wire <- renderTeardownObservations [(operation, template)]
        either (Left . refusal) (const (Right ())) (wrapObservation wire)

-- | Preserve as much UTF-8 detail as the complete single-row wire can hold.
normalizeReverseOutcome :: Text -> (ByteString -> Either Text ByteString) -> TeardownOutcome -> Either TeardownError TeardownOutcome
normalizeReverseOutcome operation wrapObservation outcome = case outcome of
    TeardownReleased -> Right TeardownReleased
    TeardownForeignRetained detail -> normalize TeardownForeignRetained detail
    TeardownRefused detail -> normalize TeardownRefused detail
    TeardownFailed detail -> normalize TeardownFailed detail
  where
    normalize constructor detail = do
        let original = Text.pack detail
            safe text = if Text.null text || text == "none" then Text.pack placeholder else text
            fits text = case renderTeardownObservations [(operation, constructor (Text.unpack (safe text)))] of
                Left _ -> False
                Right wire -> either (const False) (const True) (wrapObservation wire)
            search low high
                | low >= high = low
                | fits (Text.take middle original) = search middle high
                | otherwise = search low (middle - 1)
              where
                middle = (low + high + 1) `div` 2
            selected = if fits original then safe original else safe (Text.take (search 0 (Text.length original)) original)
        pure (constructor (Text.unpack selected))

placeholder :: String
placeholder = "no detail given"

-- | Advance one exact descent only from canonical child terminal observations.
withStorelessReverseDescentResultKernel ::
    TeardownForest scope planId frame verb ->
    Text ->
    ByteString ->
    (TeardownForest scope planId frame verb -> result) ->
    Either TeardownError result
withStorelessReverseDescentResultKernel forest child observed use =
    eliminateTeardownProgress
        (nextTeardownWork forest)
        (const (Left (refusal "the reverse frame is already complete")))
        ( \point ->
            withTeardownAuthorization
                point
                (const (Left (refusal "a descent result cannot settle a reachability step")))
                ( \_ work ->
                    eliminateTeardownWork
                        work
                        (const (Left (refusal "a descent result cannot settle local work")))
                        ( \descent ->
                            if descentWorkChildFrame descent /= child
                                then Left (refusal "the Descend response names another child frame")
                                else withDescentWorkSubtree descent $ \projection -> do
                                    rows <- teardownObservationsFromWire observed
                                    settled <- verifyObservations projection rows
                                    successor <- settleDescentWork descent settled
                                    Right (use successor)
                        )
                )
        )
  where
    refusal = TeardownReverseDescentRefused

verifyObservations ::
    TeardownPlan scope planId frame verb ->
    [(Text, TeardownOutcome)] ->
    Either TeardownError (SubtreeSettled scope planId frame verb)
verifyObservations projection observations = do
    opened <- openTeardownForest projection
    completed <- replay opened observations
    verifySubtreeSettled projection completed
  where
    replay current remaining =
        eliminateTeardownProgress
            (nextTeardownWork current)
            (\completed -> if null remaining then Right completed else mismatch current remaining)
            ( \point ->
                withTeardownAuthorization
                    point
                    (\pre -> replay (attemptPreDescentStep pre TeardownReleased) remaining)
                    ( \_ work ->
                        eliminateTeardownWork
                            work
                            ( \local -> case remaining of
                                (key, outcome) : rest
                                    | key == localWorkKey local -> replay (attemptLocalWork local outcome) rest
                                _ -> mismatch current remaining
                            )
                            ( \descent -> withDescentWorkSubtree descent $ \childProjection -> do
                                childForest <- openTeardownForest childProjection
                                let childCount = length (teardownForestOutstanding childForest)
                                    (childRows, rest) = splitAt childCount remaining
                                childSettled <- verifyObservations childProjection childRows
                                successor <- settleDescentWork descent childSettled
                                replay successor rest
                            )
                    )
            )
    mismatch current rows =
        Left
            ( TeardownTerminalObservationsMismatch
                (teardownForestOutstanding current)
                (map fst rows)
            )
