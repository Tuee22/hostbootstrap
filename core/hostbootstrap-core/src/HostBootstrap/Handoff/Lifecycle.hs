{-# LANGUAGE OverloadedStrings #-}

{- | Package-private semantic lifecycle report rendering.

Reports remain descriptive bytes until the lower completion owner admits them
against the exact live or rehydrated handoff state.
-}
module HostBootstrap.Handoff.Lifecycle
    ( withForwardLifecycleReportKernel
    , withReverseLifecycleReportKernel
    )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Authority (TeardownPhase, VerbUp)
import HostBootstrap.Command.LifecycleEntry
    ( AuthorizedChildCursor
    , LifecycleEntry
    , lifecycleEntryFrameName
    , lifecycleEntryVerbName
    , renderForwardTerminalOrigin
    , withChildRecoveryTerminalOrigin
    )
import HostBootstrap.Handoff
    ( HandoffError
    , handoffErrorMessage
    , renderForwardCompletedLifecycleReport
    , renderReverseCompletedLifecycleReport
    , takeHandoffFrame
    )
import HostBootstrap.ProjectPlan (operationKeyText)
import HostBootstrap.Teardown
    ( SubtreeSettled
    , renderTeardownObservations
    , subtreeSettledOpeningFrame
    , subtreeSettledPlanDigest
    , subtreeSettledTerminalObservations
    , subtreeSettledVerbName
    , teardownErrorMessage
    )

{- | Render one completed forward report only from its terminal cursor. -}
withForwardLifecycleReportKernel ::
    AuthorizedChildCursor
        scope specDigest planDigest brokerGeneration parentFrame
        planId configId frame VerbUp TeardownPhase ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withForwardLifecycleReportKernel #-}
withForwardLifecycleReportKernel terminal use =
    case renderForwardCompletedLifecycleReport (renderForwardTerminalOrigin terminal) of
        Left failure -> pure (Left (handoffFailure failure))
        Right report -> report `seq` use report

{- | Render one completed reverse report from the same-index sealed entry and
subtree settlement proof.
-}
withReverseLifecycleReportKernel ::
    LifecycleEntry scope planId frame brokerGeneration verb ->
    SubtreeSettled scope planId frame verb ->
    (ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withReverseLifecycleReportKernel #-}
withReverseLifecycleReportKernel entry settled use =
    withChildRecoveryTerminalOrigin entry $ \origin ->
        case reverseOriginMatches entry settled origin of
            Left failure -> pure (Left failure)
            Right () -> case renderObservations settled of
                Left failure -> pure (Left failure)
                Right observations ->
                    case renderReverseCompletedLifecycleReport origin observations of
                        Left failure -> pure (Left (handoffFailure failure))
                        Right report -> report `seq` use report

renderObservations ::
    SubtreeSettled scope planId frame verb ->
    Either Text ByteString
renderObservations =
    either (Left . Text.pack . teardownErrorMessage) Right
        . renderTeardownObservations
        . map (\(operation, outcome) -> (Text.pack (operationKeyText operation), outcome))
        . subtreeSettledTerminalObservations

reverseOriginMatches ::
    LifecycleEntry scope planId frame brokerGeneration verb ->
    SubtreeSettled scope planId frame verb ->
    ByteString ->
    Either Text ()
reverseOriginMatches entry settled raw = do
    fields <- exactFrames 16 raw
    case fields of
        [_domain, _version, _binding, snapshot, digest, _invocation, _acquisition, _cursor,
            frame, _broker, verb, commandVerb, _phase, teardownFrame, teardownVerb, _adapter] -> do
                coordinates <- traverse text
                    [snapshot, digest, frame, verb, commandVerb, teardownFrame, teardownVerb]
                case coordinates of
                    [snapshotName, digestName, frameName, verbName, commandName, teardownName, teardownVerbName]
                        | and
                            [ snapshotName == expectedDigest
                            , digestName == expectedDigest
                            , frameName == expectedFrame
                            , teardownName == expectedFrame
                            , verbName == expectedVerb
                            , commandName == expectedVerb
                            , teardownVerbName == expectedVerb
                            , lifecycleEntryFrameName entry == expectedFrame
                            , lifecycleEntryVerbName entry == expectedVerb
                            ] -> Right ()
                    _ -> Left "lifecycle completion: the reverse origin differs from its subtree proof"
        _ -> Left "lifecycle completion: the reverse terminal origin field count differs"
  where
    expectedDigest = subtreeSettledPlanDigest settled
    expectedFrame = subtreeSettledOpeningFrame settled
    expectedVerb = subtreeSettledVerbName settled
    text bytes =
        either
            (const (Left "lifecycle completion: a reverse origin field is not UTF-8"))
            Right
            (TextEncoding.decodeUtf8' bytes)

exactFrames :: Int -> ByteString -> Either Text [ByteString]
exactFrames count = go count []
  where
    go 0 fields trailing
        | ByteString.null trailing = Right (reverse fields)
        | otherwise = Left "lifecycle completion: terminal origin has trailing bytes"
    go remaining fields raw =
        case takeHandoffFrame raw of
            Left failure -> Left (handoffFailure failure)
            Right (field, trailing) -> go (remaining - 1) (field : fields) trailing

handoffFailure :: HandoffError -> Text
handoffFailure = Text.pack . handoffErrorMessage
