{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | One root-owned journal session for an exact catalog frame.

This is the only place the recursive plan catalog meets the durable session
operations, and the direction is deliberately one-way: the catalog tells this
module which frame exists and what its canonical path is, and the store tells
it what is already recorded. A request tells it nothing.

That is the whole point of the shape. Every coordinate a rooted exchange runs
on — the requester path, the session token, the stage, and the next ordinal —
is selected here from root evidence before any request is read. An 'OpenFrame'
carries only a nonce, so there is no field in it that could name a session, a
path, an ordinal, a journal key, or a catalog row even if a caller wanted to.
What a request can do is attach to a session the root already opened, or replay
an attachment that already happened; it cannot bring one into being.

A newly opened session has no predecessor-response digest, because nothing has
been answered yet. The first predecessor appears only when the exact nine-field
root-signed @Opened@ has been produced and read back, and it is the digest of
those complete signed bytes. Signing itself belongs to the live root endpoint,
not here: this module records the digest of bytes it is handed, so nothing in
it can mint a response.

Failures here are all pre-attachment, and pre-attachment failure is an outer
refusal — the authenticated-handoff transport's existing one. This module
therefore produces no rooted @Refused@ at all; that form is post-open only.
-}
module HostBootstrap.Lifecycle.Rooted (
    RootedFrameSession,
    RootedOperationJournal,
    newRootedOperationJournalKernel,
    newForwardRootedOperationJournalKernel,
    withRootedOperationJournalKernel,
    prepareRootedOperationJournalKernel,
    prepareRootedEffectJournalKernel,
    prepareRootedEffectJournalForPrerequisitesKernel,
    validateRootedJournalCoordinatesKernel,
    packageRootedJournalGateKernel,
    prepareRootedOperationJournalWithObservationsKernel,
    prepareRootedOperationJournalForPrerequisitesKernel,
    settleRootedOperationJournalKernel,
    settleRootedOperationJournalObservingKernel,
    settleRootedOperationJournalRetainingKernel,
    settleRootedReverseOperationJournalKernel,
    settleRootedReverseResourceJournalKernel,
    readRootedResourcePredecessorInEntryKernel,
    RootedResourceObservation,
    retainRootedResourceObservationsKernel,
    selectRootedResourceObservationsKernel,
    selectRootedProbeObservationsKernel,
    selectPlannedRootPrerequisitesKernel,
    observeRootedResourceInEntryKernel,
    observeRootedProviderGenerationInEntryKernel,
    observeRootedShareGenerationInEntryKernel,
    validateRootedResourceObservationInEntryKernel,
    validateRootedProbePrerequisiteInEntryKernel,
    rootedEmptyFrameProofKernel,
    RootedClusterObjectObservation,
    rootedClusterObjectNativeKernel,
    observeRootedClusterObjectKernel,
    recheckRootedClusterObjectKernel,
    withRootedPreparedResourcePredecessorKernel,
    checkRootedSettlementRowKernel,
    rootedSettlementSessionTokenKernel,
    selectRootedSettlementAddressKernel,
    publishRootedSettlementExactKernel,
    closeRootedOperationJournalKernel,
    withRootOpenedFrameSessionKernel,
    withRootOpenedDirectFrameSessionKernel,
    withAttachedRootedFrameSessionKernel,
    withRootedFrameOpeningKernel,
    withRootedFrameSessionKernel,
    withAdvancedRootedFrameSessionKernel,
    withFailedRootedFrameSessionKernel,
    cancelUnattachedRootedFrameSessionKernel,
)
where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (SomeException, throwIO, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (nub)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority (brokerEpochWord, BrokerEpoch, CommandAuthority, ExecutePhase, ProjectVerb, VerbUp, projectVerbName)
import HostBootstrap.Authority.Kernel (validateAllocatedBrokerEpochKernel)
import HostBootstrap.Handoff (
    childConfigDigest,
    frameWire,
    handoffErrorMessage,
    maxWireBytes,
    takeHandoffFrame,
 )
import HostBootstrap.Handoff.Rooted (
    RootedNodeObservation (..),
    RootedProjectedObservation (..),
    readRootedNodeObservationForPlanKernel,
    rootedLifecycleRequestFromWireKernel,
    rootedLifecycleResponseFromWireKernel,
    renderRootedLifecycleUnsignedResponseKernel,
    rootedOpenedResponseUnsignedKernel,
    withRootedLifecycleRequestKernel,
    withRootedLifecycleResponseKernel,
 )
import HostBootstrap.Handoff.Runtime (
    RecursiveHandoffRuntime,
    withRecursiveHandoffRuntimeKernel,
    withRootArmRecursiveHandoffRuntimeKernel,
 )
import HostBootstrap.Lifecycle.Prepared.Internal (
    GateAttempt (GateAttempt), GateCatalogIdentity (GateCatalogIdentity), GateCallDigest (GateCallDigest),
    GateFence (GateFence), GateFrame (GateFrame), GateJournalVersion (GateJournalVersion),
    GateOperationKey (GateOperationKey), GatePlanDigest (GatePlanDigest), GateSession (GateSession),
    GateSupersessionGeneration (GateSupersessionGeneration), GateUnknownPhase (GateUnknownPhase),
    PreparedGate, preparedGateAttempt, preparedGateEffect, preparedGateFence, preparedGateJournalVersion,
    preparedGateOperation, preparedGatePlan, preparedGateSession, renderFencedPreparedGatePackageKernel,
    renderEffectPreparedGatePackageKernel,
 )
import HostBootstrap.Lifecycle.Plan (PlannedStep, ProjectPlan, RootProbeFamily (RootChartWorkloadProbe, RootClusterProbe, RootDurableShareProbe, RootObjectStoreProbe, RootProviderProbe, RootRegistryProbe), RootProbeIdentity, forwardKernel, plannedRootProbeIdentitiesKernel, plannedStepFrameIdKernel, rootProbeIdentityCoordinatesKernel, rootProbeIdentityFamilyKernel, topologyDescentFromKernel, topologyKernel, withRootClusterObjectProbeDescriptionKernel)
import HostBootstrap.Lifecycle.RootedPlan (
    RootedPlanCatalog,
    rootedPlanCatalogRecordIdentityKernel,
    withRootedPlanCatalogEntriesKernel,
    ParentFrameId (ParentFrameId),
    ChildFrameId (ChildFrameId),
    withRootedPlanCatalogRootKernel,
 )
import HostBootstrap.Lifecycle.ResourceRecord (checkResourceSettlementKernel, persistResourceSettlementKernel, resourceRecordKeyKernel, verifyExactResourceRecordBundleKernel, verifyRecoveredResourceReleaseKernel, withVerifiedResourceRecordBundleKernel)
import HostBootstrap.Lifecycle.Session (
    FenceEpoch,
    LifecycleCursor,
    IntentOrigin (NoHistory),
    OperationSession,
    ProjectPermit,
    SessionError,
    acknowledgeOutcome,
    closeOperationSession,
    currentFence,
    fenceEpochWord,
    openProjectJournal,
    operationSessionId,
    operationSessionMatchesPlan,
    sessionIdText,
    publishRootedSettlementRowKernel,
    projectPermitVersion,
    registerOperationIntent,
    validatePreparedGateForSettlementKernel,
    withOperationAdvance,
    withPreparedGate,
    withPreparedGateForEffect,
    withLifecyclePrepareEntry,
    lifecycleCursorFrame,
    attachRootedFrameSessionRecordKernel,
    cancelOpenedRootedFrameSessionRecordKernel,
    openRootedFrameSessionRecordKernel,
    rootedFrameSessionKeyKernel,
    rootedDirectFrameSessionKeyKernel,
    sessionErrorMessage,
 )
import HostBootstrap.ProjectPlan (renderSnapshot, stablePlanSnapshotDigest)
import HostBootstrap.ProjectPlan.Frame (currentFrameId)
import HostBootstrap.Step (ClusterObjectProbeDescription, TeardownOutcome (..))
import HostBootstrap.Protected (
    Expectation (ExpectVersion),
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    RecordVersion,
    compareAndDeleteProtectedRecord,
    mkRecordKey,
    protectedErrorMessage,
    protectedRecordBytes,
    protectedRecordVersion,
    protectedStoreIdentity,
    protectedStoreIdentityText,
    readProtectedRecord,
    sessionStoreIdentity,
    withProtectedEntry,
 )

{- | The root's retained plan-indexed operation session and its latest permit.

The existential plan index cannot escape. The lock serializes all journal
transitions, and a refused transition poisons this in-memory handle so a caller
cannot reuse a permit after a partial durable write. The open durable session is
then left for recovery.
-}
data RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb where
    RootedOperationJournal ::
        ProtectedStore ->
        BrokerEpoch brokerGeneration ->
        OperationSession scope planId ->
        FenceEpoch scope planId ->
        (forall entry. ProtectedSession entry -> IO (Either Text ())) ->
        MVar (Maybe (ProjectPermit scope planId, [(Text, PreparedGate)])) ->
        MVar Bool ->
        RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb

type role RootedOperationJournal nominal nominal nominal nominal nominal nominal nominal

newRootedOperationJournalKernel ::
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ProtectedStore -> BrokerEpoch brokerGeneration -> OperationSession scope planId ->
    FenceEpoch scope planId -> ProjectPermit scope planId ->
    IO (RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb)
newRootedOperationJournalKernel _frameSession store epoch session fence permit =
    RootedOperationJournal store epoch session fence (const (pure (Right ()))) <$> newMVar (Just (permit, [])) <*> newMVar False

-- | Retain the root's acquisition for validation inside every forward prepare entry.
newForwardRootedOperationJournalKernel ::
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId VerbUp ->
    ProtectedStore -> BrokerEpoch brokerGeneration -> OperationSession scope planId ->
    FenceEpoch scope planId -> ProjectPermit scope planId ->
    CommandAuthority scope rootPlanId rootFrame brokerGeneration VerbUp ExecutePhase ->
    LifecycleCursor scope rootPlanId rootFrame brokerGeneration VerbUp ExecutePhase ->
    IO (RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId VerbUp)
newForwardRootedOperationJournalKernel _frameSession store epoch session fence permit authority cursor =
    RootedOperationJournal store epoch session fence validate <$> newMVar (Just (permit, [])) <*> newMVar False
  where
    validate :: ProtectedSession entry -> IO (Either Text ())
    validate protected = do
        result <- withLifecyclePrepareEntry protected authority cursor (lifecycleCursorFrame cursor) (pure (Right ()))
        pure (either (Left . Text.pack . sessionErrorMessage) Right result)

withRootedOperationJournalKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ( forall planId.
      ProtectedStore -> BrokerEpoch brokerGeneration -> OperationSession scope planId -> FenceEpoch scope planId ->
      ProjectPermit scope planId -> [(Text, PreparedGate)] ->
      IO (Either Text (ProjectPermit scope planId, [(Text, PreparedGate)], result))
    ) -> IO (Either Text result)
withRootedOperationJournalKernel (RootedOperationJournal store epoch session fence _ state _) use = do
    result <- modifyMVar state $ \current -> case current of
        Nothing -> pure (Nothing, Right (Left "rooted operation journal: the retained permit is no longer usable"))
        Just (permit, pending) -> do
            attempted <- tryRootedJournalAction (use store epoch session fence permit pending)
            pure $ case attempted of
                Left exception -> (Nothing, Left exception)
                Right (Left failure) -> (Nothing, Right (Left failure))
                Right (Right (successor, nextPending, value)) -> (Just (successor, nextPending), Right (Right value))
    either throwIO pure result

tryRootedJournalAction :: IO result -> IO (Either SomeException result)
tryRootedJournalAction = try

{- | Close once, returning the same successful result for an exact in-process retry.

The close lock serializes retries. A failed close leaves the handle poisoned for
recovery, rather than issuing a completion for an unsettled operation.
-}
closeRootedOperationJournalKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb -> IO (Either Text ())
closeRootedOperationJournalKernel journal@(RootedOperationJournal _ _ _ _ _ _ closed) =
    modifyMVar closed $ \alreadyClosed ->
        if alreadyClosed
            then pure (True, Right ())
            else do
                result <- withRootedOperationJournalKernel journal $ \store epoch session _fence permit pending ->
                    if not (null pending)
                        then pure (Left "rooted operation journal: unsettled gates prevent closure")
                        else do
                            entered <- withProtectedEntry store $ \protected -> do
                                live <- validateAllocatedBrokerEpochKernel protected epoch
                                case live of
                                    Left failure -> pure (Right (Left (Text.pack (show failure))))
                                    Right () -> do
                                        result <- closeOperationSession protected session permit
                                        pure (Right (either (Left . Text.pack . sessionErrorMessage) Right result))
                            pure $ case entered of
                                Left failure -> Left (Text.pack (show failure))
                                Right (Left failure) -> Left failure
                                Right (Right successor) -> Right (successor, [], ())
                pure (either (const False) (const True) result, result)

{- | Publish the exact unknown records for ordered operations before returning gates.

An outstanding gate is reused only for the same operation; newly admitted gates
consume the current permit in order. A failure invalidates the retained handle,
leaving any already committed unknown rows to recovery.
-}
prepareRootedOperationJournalKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    [Text] -> IO (Either Text [PreparedGate])
prepareRootedOperationJournalKernel journal = prepareRootedOperationJournalWithObservationsKernel journal []

-- | Check the journal's retained authority before minting a node grant.
validateRootedJournalCoordinatesKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text -> Word64 -> Text -> Text -> IO (Either Text Bool)
validateRootedJournalCoordinatesKernel journal runtimeStore generation localDigest token =
    withRootedOperationJournalKernel journal $ \journalStore epoch operationSession fence permit pending -> do
        observed <- withProtectedEntry journalStore $ \protected -> Right <$> currentFence protected permit
        let liveFence = case observed of Right (Right actual) -> fenceEpochWord actual == fenceEpochWord fence; _ -> False
        pure (Right (permit, pending, liveFence && protectedStoreIdentityText (protectedStoreIdentity journalStore) == runtimeStore
            && brokerEpochWord epoch == generation && operationSessionMatchesPlan localDigest operationSession
            && sessionIdText (operationSessionId operationSession) == token <> "-f" <> Text.pack (show (fenceEpochWord fence)) && fenceEpochWord fence > 0))

-- | Package only the exact committed journal gate selected by the root.
packageRootedJournalGateKernel :: Text -> Text -> Text -> Text -> Word64 -> Bool -> PreparedGate -> Either Text ByteString
packageRootedJournalGateKernel localDigest catalog frame token generation effectAware gate = do
    requireGateCoordinate "the journal gate names another plan" (preparedGatePlan gate == localDigest)
    requireGateCoordinate "the journal gate names another session" (preparedGateSession gate == token <> "-f" <> Text.pack (show (preparedGateFence gate)))
    requireGateCoordinate "the journal gate has no observed fence" (preparedGateFence gate > 0)
    let fenced = renderFencedPreparedGatePackageKernel (GatePlanDigest localDigest) (GateCatalogIdentity catalog)
            (GateFrame frame) (GateSession token) (GateOperationKey (preparedGateOperation gate))
            (GateSupersessionGeneration generation) (GateFence (preparedGateFence gate)) (GateAttempt (preparedGateAttempt gate))
            (GateJournalVersion (preparedGateJournalVersion gate))
    case (effectAware, preparedGateEffect gate) of
        (False, Nothing) -> Right fenced
        (True, Just (phase, digest)) -> renderEffectPreparedGatePackageKernel fenced phase digest
        _ -> Left "rooted node: the journal gate does not carry the requested effect"
  where
    requireGateCoordinate _ True = Right ()
    requireGateCoordinate detail False = Left ("rooted node: " <> detail)

-- | Prepare ordered operations under explicit effect coordinates. Callers must
-- authenticate or derive the coordinates before entering this private route.
prepareRootedEffectJournalKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    [(Text, Text, Text)] -> IO (Either Text [PreparedGate])
prepareRootedEffectJournalKernel journal effects
    | any (\(_, phase, digest) -> invalid phase || invalid digest) effects =
        pure (Left "rooted operation journal: invalid effect coordinates")
    | otherwise = prepareRootedOperationJournalWithChecksAndEffects journal [] [] (map (\(operation, _, _) -> operation) effects) (Just effects)
  where
    invalid value = Text.null value || Text.any (== '\t') value

-- | Recheck the exact prerequisites before recording supplied effects.
prepareRootedEffectJournalForPrerequisitesKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    [RootProbeIdentity] -> [RootedResourceObservation] -> [(Text, Text, Text)] -> IO (Either Text [PreparedGate])
prepareRootedEffectJournalForPrerequisitesKernel journal@(RootedOperationJournal store _ _ _ _ _ _) identities retained effects
    | any (\(_, phase, digest) -> invalid phase || invalid digest) effects =
        pure (Left "rooted operation journal: invalid effect coordinates")
    | otherwise = case selectRootedProbeObservationsKernel store identities retained of
        Left failure -> pure (Left failure)
        Right observations -> prepareRootedOperationJournalWithChecksAndEffects journal [] (zip identities observations) (map (\(operation, _, _) -> operation) effects) (Just effects)
  where
    invalid value = Text.null value || Text.any (== '\t') value

-- | Select exact plan-derived prerequisite identities before the entry-scoped
-- ownership and physical-version rechecks. This does not run backend probes or
-- establish that the supplied identity set is complete for an operation.
prepareRootedOperationJournalForPrerequisitesKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    [RootProbeIdentity] -> [RootedResourceObservation] -> [Text] -> IO (Either Text [PreparedGate])
prepareRootedOperationJournalForPrerequisitesKernel journal@(RootedOperationJournal store _ _ _ _ _ _) identities retained operations =
    case selectRootedProbeObservationsKernel store identities retained of
        Left failure -> pure (Left failure)
        Right observations -> prepareRootedOperationJournalWithChecks journal [] (zip identities observations) operations

-- | Recheck root-observed records in the same protected entry as preparation.
prepareRootedOperationJournalWithObservationsKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    [RootedResourceObservation] -> [Text] -> IO (Either Text [PreparedGate])
prepareRootedOperationJournalWithObservationsKernel journal observations =
    prepareRootedOperationJournalWithChecks journal observations []

prepareRootedOperationJournalWithChecks ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    [RootedResourceObservation] -> [(RootProbeIdentity, RootedResourceObservation)] -> [Text] -> IO (Either Text [PreparedGate])
prepareRootedOperationJournalWithChecks journal observations prerequisites operations =
    prepareRootedOperationJournalWithChecksAndEffects journal observations prerequisites operations Nothing

prepareRootedOperationJournalWithChecksAndEffects ::
    forall scope rootPlanId brokerGeneration catalogId frame sessionId verb.
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    [RootedResourceObservation] -> [(RootProbeIdentity, RootedResourceObservation)] -> [Text] ->
    Maybe [(Text, Text, Text)] -> IO (Either Text [PreparedGate])
prepareRootedOperationJournalWithChecksAndEffects journal@(RootedOperationJournal _ _ _ _ validate _ _) observations prerequisites operations effects
    | null operations || any Text.null operations || length operations /= length (nub operations) =
        pure (Left "rooted operation journal: invalid or duplicate operation keys")
    | otherwise = withRootedOperationJournalKernel journal $ \store epoch session fence permit pending -> do
        entered <- withProtectedEntry store $ \protected -> do
            acquisition <- validate protected
            case acquisition of
                Left failure -> pure (Right (Left failure))
                Right () -> do
                    live <- validateAllocatedBrokerEpochKernel protected epoch
                    case live of
                        Left failure -> pure (Right (Left (Text.pack (show failure))))
                        Right () -> do
                            observedFence <- currentFence protected permit
                            case observedFence of
                                Left failure -> pure (Right (Left (Text.pack (sessionErrorMessage failure))))
                                Right current
                                    | fenceEpochWord current /= fenceEpochWord fence ->
                                        pure (Right (Left "rooted operation journal: the operation fence is stale"))
                                    | otherwise -> do
                                        checked <- traverse (validateRootedResourceObservationInEntryKernel protected) observations
                                        checkedPrerequisites <- traverse (uncurry (validateRootedProbePrerequisiteInEntryKernel protected)) prerequisites
                                        case sequence_ (checked ++ checkedPrerequisites) of
                                            Left failure -> pure (Right (Left failure))
                                            Right () -> Right <$> prepare protected epoch session fence permit pending operations []
        pure $ case entered of
            Left failure -> Left (Text.pack (show failure))
            Right outcome -> outcome
  where
    prepare :: forall protected planId.
        ProtectedSession protected -> BrokerEpoch brokerGeneration -> OperationSession scope planId ->
        FenceEpoch scope planId -> ProjectPermit scope planId -> [(Text, PreparedGate)] -> [Text] ->
        [PreparedGate] -> IO (Either Text (ProjectPermit scope planId, [(Text, PreparedGate)], [PreparedGate]))
    prepare _ _ _ _ permit pending [] collected = pure (Right (permit, pending, reverse collected))
    prepare protected epoch session fence permit pending (operation : rest) collected =
        case lookup operation pending of
            Just gate
                | preparedGateEffect gate == expectedEffect operation ->
                    prepare protected epoch session fence permit pending rest (gate : collected)
                | otherwise -> pure (Left "rooted operation journal: pending gate names another effect")
            Nothing -> do
                registered <- registerOperationIntent protected session operation NoHistory permit
                case registered of
                    Left failure -> pure (Left (Text.pack (sessionErrorMessage failure)))
                    Right registeredPermit -> do
                        prepared <- case expectedEffect operation of
                            Nothing -> withPreparedGate protected session epoch fence operation "EffectOutcomeUnknown" registeredPermit (\gate successor -> pure (Right (gate, successor)))
                            Just (GateUnknownPhase phase, GateCallDigest digest) ->
                                withPreparedGateForEffect protected session epoch fence operation phase digest registeredPermit (\gate successor -> pure (Right (gate, successor)))
                        case prepared of
                            Left failure -> pure (Left (Text.pack (sessionErrorMessage failure)))
                            Right (gate, successor) ->
                                prepare protected epoch session fence successor ((operation, gate) : pending) rest (gate : collected)

    expectedEffect operation = do
        supplied <- effects
        (phase, digest) <- lookup operation [(key, (phase, digest)) | (key, phase, digest) <- supplied]
        pure (GateUnknownPhase phase, GateCallDigest digest)


{- | Persist reported resource settlements before acknowledging their unknown gates.

The report is rechecked against the exact frame and ordered plan operations.
Unused projections remain pending after success; a definite node failure settles
all its prepared gates as terminal. Any partial write invalidates the retained
handle and leaves the durable session to recovery.
-}
settleRootedOperationJournalKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text -> Text -> [Text] -> ByteString -> IO (Either Text ())
settleRootedOperationJournalKernel journal frame node projections raw =
    fmap (fmap (const ())) (settleRootedOperationJournalObservingKernel journal frame node projections raw)

-- | Serialize settlement and retention across the root's frame services.
settleRootedOperationJournalRetainingKernel ::
    MVar [RootedResourceObservation] ->
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text -> Text -> [Text] -> ByteString -> IO (Either Text ())
settleRootedOperationJournalRetainingKernel retained journal frame node projections raw =
    case readRootedNodeObservationForPlanKernel frame node projections raw of
        Left failure -> pure (Left failure)
        Right (RootedNodeObservation _ succeeded _ _) ->
            modifyMVar retained $ \previous -> do
                settled <- settleRootedOperationJournalObservingKernel journal frame node projections raw
                let next = case settled of
                        Right current | succeeded -> retainRootedResourceObservationsKernel previous current
                        _ -> previous
                pure (next, () <$ settled)

-- | Return only observations captured under the same entry as settlement.
settleRootedOperationJournalObservingKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text -> Text -> [Text] -> ByteString -> IO (Either Text [RootedResourceObservation])
settleRootedOperationJournalObservingKernel journal frame node projections raw =
    case readRootedNodeObservationForPlanKernel frame node projections raw of
        Left failure -> pure (Left failure)
        Right (RootedNodeObservation _ succeeded _ entries) ->
            withRootedOperationJournalKernel journal $ \store epoch session fence permit pending -> do
                entered <- withProtectedEntry store $ \protected -> do
                    live <- validateAllocatedBrokerEpochKernel protected epoch
                    case live of
                        Left failure -> pure (Right (Left (Text.pack (show failure))))
                        Right () -> case traverse (\(RootedProjectedObservation key _ _) -> lookup key pending) entries of
                            Nothing -> pure (Right (Left "rooted operation journal: the observation has no prepared gate"))
                            Just [] -> pure (Right (Left "rooted operation journal: the observation has no node gate"))
                            Just gates@(first : _) -> do
                                current <- openProjectJournal protected (preparedGatePlan first)
                                observedFence <- currentFence protected permit
                                case (current, observedFence) of
                                    (Left failure, _) -> pure (Right (Left (Text.pack (sessionErrorMessage failure))))
                                    (_, Left failure) -> pure (Right (Left (Text.pack (sessionErrorMessage failure))))
                                    (Right currentPermit, Right currentEpoch)
                                        | projectPermitVersion currentPermit /= projectPermitVersion permit ->
                                            pure (Right (Left "rooted operation journal: the retained permit is stale"))
                                        | fenceEpochWord currentEpoch /= fenceEpochWord fence || any ((/= fenceEpochWord fence) . preparedGateFence) gates ->
                                            pure (Right (Left "rooted operation journal: the operation fence is stale"))
                                        | otherwise -> do
                                            checked <- traverse (\gate -> validatePreparedGateForSettlementKernel protected session gate permit) gates
                                            case sequence checked of
                                                Left failure -> pure (Right (Left (Text.pack (sessionErrorMessage failure))))
                                                Right _ -> do
                                                    resources <- traverse (\(RootedProjectedObservation _ _ resource, gate) -> checkResource protected session gate permit resource) (zip entries gates)
                                                    case sequence resources of
                                                        Left failure -> pure (Right (Left failure))
                                                        Right _ -> Right <$> settle protected session permit pending succeeded entries
                pure $ case entered of
                    Left failure -> Left (Text.pack (show failure))
                    Right outcome -> outcome
  where
    settle _ _ permit pending _ [] = pure (Right (permit, pending, []))
    settle protected session permit pending succeeded (RootedProjectedObservation operation taken resource : rest) =
        case lookup operation pending of
            Nothing -> pure (Left "rooted operation journal: the observation has no prepared gate")
            Just gate
                | not taken && succeeded -> settle protected session permit pending succeeded rest
                | otherwise -> do
                    persisted <- persistResource protected session gate permit resource
                    case persisted of
                        Left failure -> pure (Left failure)
                        Right () -> do
                            observed <- case resource of
                                Nothing -> pure (Right [])
                                Just (resourceFrame, _, _) -> fmap (fmap (: [])) (observeRootedResourceInEntryKernel protected resourceFrame (preparedGatePlan gate) operation)
                            case observed of
                                Left failure -> pure (Left failure)
                                Right current -> do
                                    acknowledged <- acknowledgeOutcome protected session gate (if succeeded then "Committed" else "StepObservedTerminal") () permit
                                    case acknowledged of
                                        Left failure -> pure (Left (Text.pack (sessionErrorMessage failure)))
                                        Right advanced -> withOperationAdvance advanced $ \() successor -> do
                                            remaining <- settle protected session successor (filter ((/= operation) . fst) pending) succeeded rest
                                            pure (fmap (\(next, nextPending, found) -> (next, nextPending, current ++ found)) remaining)

    checkResource _ _ _ _ Nothing = pure (Right ())
    checkResource protected session gate permit (Just (resourceFrame, expected, bytes)) = do
        valid <- validatePreparedGateForSettlementKernel protected session gate permit
        case valid of
            Left failure -> pure (Left (Text.pack (sessionErrorMessage failure)))
            Right () -> checkResourceSettlementKernel protected (preparedGatePlan gate) resourceFrame (preparedGateOperation gate) expected bytes
    persistResource _ _ _ _ Nothing = pure (Right ())
    persistResource protected session gate permit (Just (resourceFrame, expected, bytes)) = do
        valid <- validatePreparedGateForSettlementKernel protected session gate permit
        case valid of
            Left failure -> pure (Left (Text.pack (sessionErrorMessage failure)))
            Right () -> persistResourceSettlementKernel protected (preparedGatePlan gate) resourceFrame (preparedGateOperation gate) expected bytes

{- | Settle one authenticated reverse observation under its prepared gate.

The caller must first bind the observation to the exact rooted request and its
current teardown work. This transition records only that observation; it does
not manufacture a resource settlement or infer that a foreign object was ours.
-}
settleRootedReverseOperationJournalKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text -> TeardownOutcome -> IO (Either Text ())
settleRootedReverseOperationJournalKernel journal operation outcome =
    withRootedOperationJournalKernel journal $ \store epoch session _fence permit pending ->
        case lookup operation pending of
            Nothing -> pure (Left "rooted operation journal: the reverse observation has no prepared gate")
            Just gate -> do
                entered <- withProtectedEntry store $ \protected -> do
                    live <- validateAllocatedBrokerEpochKernel protected epoch
                    case live of
                        Left failure -> pure (Right (Left (Text.pack (show failure))))
                        Right () -> do
                            acknowledged <- acknowledgeOutcome protected session gate (phase outcome) () permit
                            case acknowledged of
                                Left failure -> pure (Right (Left (Text.pack (sessionErrorMessage failure))))
                                Right advanced -> withOperationAdvance advanced $ \() successor ->
                                    pure (Right (Right successor))
                pure $ case entered of
                    Left failure -> Left (Text.pack (show failure))
                    Right (Left failure) -> Left failure
                    Right (Right successor) -> Right (successor, filter ((/= operation) . fst) pending, ())
  where
    phase TeardownReleased = "Released"
    phase (TeardownForeignRetained _) = "ObservedForeign"
    phase (TeardownRefused _) = "StepObservedTerminal"
    phase (TeardownFailed _) = "StepObservedTerminal"

-- | Settle a recovered owned resource only after its exact release transition,
-- predecessor, broker epoch, and prepared operation gate all agree.
settleRootedReverseResourceJournalKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Maybe (RecordKey, ByteString) ->
    Text -> TeardownOutcome -> ByteString -> ByteString -> IO (Either Text ())
settleRootedReverseResourceJournalKernel journal frameSession checkpoint operation outcome previous successor =
    withRootedFrameSessionKernel frameSession $ \attached _ _ _ frame _ _ _ _ _ ->
        if not attached
            then pure (Left "rooted operation journal: release requires an attached frame")
            else case outcome of
                TeardownReleased -> settle frame
                _ -> pure (Left "rooted operation journal: only a released outcome carries a release transition")
  where
    settle frame = withRootedOperationJournalKernel journal $ \store epoch session _fence permit pending ->
        case lookup operation pending of
            Nothing -> pure (Left "rooted operation journal: the release has no prepared gate")
            Just gate -> do
                entered <- withProtectedEntry store $ \protected -> do
                    live <- validateAllocatedBrokerEpochKernel protected epoch
                    case live of
                        Left failure -> pure (Right (Left (Text.pack (show failure))))
                        Right () -> do
                            valid <- validatePreparedGateForSettlementKernel protected session gate permit
                            case valid of
                                Left failure -> pure (Right (Left (Text.pack (sessionErrorMessage failure))))
                                Right () -> case verifyRecoveredResourceReleaseKernel (preparedGatePlan gate) frame operation previous successor of
                                    Left failure -> pure (Right (Left failure))
                                    Right () -> do
                                        checked <- checkResourceSettlementKernel protected (preparedGatePlan gate) frame operation (Just previous) successor
                                        case checked of
                                            Left failure -> pure (Right (Left failure))
                                            Right () -> do
                                                recorded <- case checkpoint of
                                                    Nothing -> pure (Right ())
                                                    Just (key, row) -> do
                                                        published <- publishRootedSettlementRowKernel protected key row
                                                        pure $ case published of
                                                            Left failure -> Left (Text.pack (sessionErrorMessage failure))
                                                            Right (_, present) | present == row -> Right ()
                                                            Right _ -> Left "rooted operation journal: the settlement checkpoint conflicts"
                                                case recorded of
                                                    Left failure -> pure (Right (Left failure))
                                                    Right () -> do
                                                        persisted <- persistResourceSettlementKernel protected (preparedGatePlan gate) frame operation (Just previous) successor
                                                        case persisted of
                                                            Left failure -> pure (Right (Left failure))
                                                            Right () -> do
                                                                acknowledged <- acknowledgeOutcome protected session gate "Released" () permit
                                                                case acknowledged of
                                                                    Left failure -> pure (Right (Left (Text.pack (sessionErrorMessage failure))))
                                                                    Right advanced -> withOperationAdvance advanced $ \() next -> pure (Right (Right next))
                pure $ case entered of
                    Left failure -> Left (Text.pack (show failure))
                    Right (Left failure) -> Left failure
                    Right (Right next) -> Right (next, filter ((/= operation) . fst) pending, ())

-- | Refuse an existing different settlement before any journal transition.
checkRootedSettlementRowKernel :: ProtectedStore -> RecordKey -> ByteString -> IO (Either Text ()) -> IO (Either Text ())
checkRootedSettlementRowKernel store key expected beforePublish = do
    observed <- withProtectedEntry store (\protected -> readProtectedRecord protected key)
    case observed of
        Left failure -> pure (Left (Text.pack (show failure)))
        Right (Just row) | protectedRecordBytes row /= expected -> pure (Left "the durable settlement row conflicts")
        _ -> beforePublish

-- | Use the authenticated opening nonce to distinguish separate attachments.
rootedSettlementSessionTokenKernel :: RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb -> Maybe Text
rootedSettlementSessionTokenKernel session = case session of
    OpenedRootedFrameSession{} -> Nothing
    AttachedRootedFrameSession (OpenedFrameFields _ _ _ _ _ token _ _ _ _ _) nonce _ _ _ ->
        Just (token <> "-" <> childConfigDigest nonce)

-- | Existing unscoped rows are replayed only when their bytes match exactly.
selectRootedSettlementAddressKernel :: ProtectedStore -> RecordKey -> ByteString -> RecordKey -> ByteString -> IO (Either Text (RecordKey, ByteString))
selectRootedSettlementAddressKernel store legacyKey legacyRow scopedKey scopedRow = do
    observed <- withProtectedEntry store (\entry -> readProtectedRecord entry legacyKey)
    pure $ case observed of
        Left failure -> Left (Text.pack (show failure))
        Right Nothing -> Right (scopedKey, scopedRow)
        Right (Just row)
            | protectedRecordBytes row == legacyRow -> Right (legacyKey, legacyRow)
            | otherwise -> Left "the legacy durable settlement row conflicts"

-- | Publish and read back one exact settlement without replacing a conflict.
publishRootedSettlementExactKernel :: ProtectedStore -> RecordKey -> ByteString -> IO (Either Text ())
publishRootedSettlementExactKernel store key expected = do
    entered <- withProtectedEntry store $ \protected -> Right <$> publishRootedSettlementRowKernel protected key expected
    pure $ case entered of
        Left failure -> Left ("rooted node: " <> Text.pack (show failure))
        Right (Left failure) -> Left ("rooted node: " <> Text.pack (sessionErrorMessage failure))
        Right (Right (_, present))
            | present /= expected -> Left "rooted node: the durable settlement row is not this preparation"
            | otherwise -> Right ()

-- | Root-observed physical record, scoped to its actual protected store.
data RootedResourceObservation = RootedResourceObservation Text RecordKey RecordVersion ByteString

-- | Replace only the same store and record key with the latest captured row.
retainRootedResourceObservationsKernel ::
    [RootedResourceObservation] -> [RootedResourceObservation] -> [RootedResourceObservation]
retainRootedResourceObservationsKernel = foldl retain
  where
    retain previous current@(RootedResourceObservation store key _ _) =
        filter (\(RootedResourceObservation oldStore oldKey _ _) -> oldStore /= store || oldKey /= key) previous ++ [current]

-- | Select exactly the requested plan resources, in plan order, from this store.
selectRootedResourceObservationsKernel ::
    ProtectedStore -> [(Text, Text, Text)] -> [RootedResourceObservation] -> Either Text [RootedResourceObservation]
selectRootedResourceObservationsKernel store coordinates retained = do
    keys <- traverse (\(plan, frame, resource) -> resourceRecordKeyKernel plan frame resource >>= either (Left . protectedErrorMessage) Right . mkRecordKey) coordinates
    if length keys /= length (nub keys)
        then Left "rooted resource observation: duplicate required resource"
        else traverse select keys
  where
    storeName = protectedStoreIdentityText (protectedStoreIdentity store)
    select key = case [row | row@(RootedResourceObservation name found _ _) <- retained, name == storeName && found == key] of
        [] -> Left "rooted resource observation: required resource was not observed"
        [row] -> Right row
        _ -> Left "rooted resource observation: duplicate retained resource"

-- | Select protected observations only through plan-derived probe identities.
-- This checks record identity, not backend readiness or grant authority.
selectRootedProbeObservationsKernel ::
    ProtectedStore -> [RootProbeIdentity] -> [RootedResourceObservation] -> Either Text [RootedResourceObservation]
selectRootedProbeObservationsKernel store identities =
    selectRootedResourceObservationsKernel store
        [(plan, frame, operation) | identity <- identities, let (plan, frame, operation, _) = rootProbeIdentityCoordinatesKernel identity]

-- | Derive the complete ordered prerequisite set from the admitted node;
-- retained observations cannot add, omit or reorder its requirements. The
-- result establishes protected-record selection, not native backend readiness.
selectPlannedRootPrerequisitesKernel ::
    ProtectedStore ->
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedStep scope planId configId (cfg scope) ->
    Text ->
    [RootedResourceObservation] ->
    Either Text (RootProbeIdentity, [(RootProbeIdentity, RootedResourceObservation)])
selectPlannedRootPrerequisitesKernel store plan node operation retained = do
    (target, prerequisites) <- either (Left . Text.pack . show) Right (plannedRootProbeIdentitiesKernel plan node operation)
    selected <- selectRootedProbeObservationsKernel store prerequisites retained
    pure (target, zip prerequisites selected)

observeRootedResourceInEntryKernel ::
    ProtectedSession session -> Text -> Text -> Text -> IO (Either Text RootedResourceObservation)
observeRootedResourceInEntryKernel protected frame plan operation =
    case resourceRecordKeyKernel plan frame operation >>= either (Left . protectedErrorMessage) Right . mkRecordKey of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord protected key
            pure $ case observed of
                Left failure -> Left (protectedErrorMessage failure)
                Right Nothing -> Left "rooted resource observation: resource record is absent"
                Right (Just record) -> do
                    let bytes = protectedRecordBytes record
                    _ <- verifyExactResourceRecordBundleKernel plan frame operation bytes
                    Right (RootedResourceObservation (protectedStoreIdentityText (sessionStoreIdentity protected)) key (protectedRecordVersion record) bytes)

-- | Compare both physical version and bytes while the caller holds the entry.
validateRootedResourceObservationInEntryKernel ::
    ProtectedSession session -> RootedResourceObservation -> IO (Either Text ())
validateRootedResourceObservationInEntryKernel protected (RootedResourceObservation store key version bytes)
    | protectedStoreIdentityText (sessionStoreIdentity protected) /= store =
        pure (Left "rooted resource observation: protected store differs")
    | otherwise = do
        observed <- readProtectedRecord protected key
        pure $ case observed of
            Left failure -> Left (protectedErrorMessage failure)
            Right Nothing -> Left "rooted resource observation: resource record is absent"
            Right (Just record)
                | protectedRecordVersion record /= version -> Left "rooted resource observation: physical version changed"
                | protectedRecordBytes record /= bytes -> Left "rooted resource observation: resource bytes changed"
                | otherwise -> Right ()

-- | Require the exact plan-derived prerequisite to remain an owned protected
-- record at the observed physical version. This is not backend readiness.
validateRootedProbePrerequisiteInEntryKernel ::
    ProtectedSession session -> RootProbeIdentity -> RootedResourceObservation -> IO (Either Text ())
validateRootedProbePrerequisiteInEntryKernel protected identity observation@(RootedResourceObservation _ observedKey _ bytes) =
    case resourceRecordKeyKernel plan frame operation >>= either (Left . protectedErrorMessage) Right . mkRecordKey of
        Left failure -> pure (Left failure)
        Right expectedKey
            | expectedKey /= observedKey -> pure (Left "rooted probe prerequisite: resource identity differs")
            | otherwise -> case verifyExactResourceRecordBundleKernel plan frame operation bytes of
                Left failure -> pure (Left failure)
                Right bundle ->
                    withVerifiedResourceRecordBundleKernel bundle
                        (\_ _ _ -> validateRootedResourceObservationInEntryKernel protected observation)
                        (\_ _ _ _ _ _ _ -> pure (Left "rooted probe prerequisite: resource is released"))
  where
    (plan, frame, operation, _) = rootProbeIdentityCoordinatesKernel identity

{- | The root's observation of one plan-owned in-cluster object: the admitted
identity, the description recovered from that identity alone, the exact current
unreleased record it was read under, and the native identity the cluster
reported. It grants nothing.
-}
data RootedClusterObjectObservation native
    = RootedClusterObjectObservation RootProbeIdentity ClusterObjectProbeDescription RootedResourceObservation native

rootedClusterObjectNativeKernel :: RootedClusterObjectObservation native -> native
rootedClusterObjectNativeKernel (RootedClusterObjectObservation _ _ _ native) = native

{- | Observe the plan-owned cluster, object store, registry or chart workload at the root.

The description comes only from the admitted plan through the exact identity,
so a foreign plan or another node selects nothing. The record must be current
and unreleased on both sides of the native query, which receives only that
description; a missing record, a released or replaced one, and a native
refusal (an absent kubeconfig or object) all refuse before any effect.
-}
observeRootedClusterObjectKernel ::
    ProtectedStore ->
    ProjectPlan scope specDigest planId configId cfg ->
    RootProbeIdentity ->
    (ClusterObjectProbeDescription -> IO (Either Text native)) ->
    IO (Either Text (RootedClusterObjectObservation native))
observeRootedClusterObjectKernel store plan identity observeNative
    | rootProbeIdentityFamilyKernel identity `notElem` [RootObjectStoreProbe, RootRegistryProbe, RootClusterProbe, RootChartWorkloadProbe] =
        pure (Left (refusal "the identity is not a cluster or in-cluster object resource"))
    | otherwise = do
        let (digest, frame, operation, _) = rootProbeIdentityCoordinatesKernel identity
        case withRootClusterObjectProbeDescriptionKernel plan identity id of
            Left failure -> pure (Left (refusal (Text.pack (show failure))))
            Right description -> do
                entered <- inEntry $ \protected -> do
                    observed <- observeRootedResourceInEntryKernel protected frame digest operation
                    case observed of
                        Left failure -> pure (Left failure)
                        Right row -> fmap (const row) <$> validateRootedProbePrerequisiteInEntryKernel protected identity row
                case entered of
                    Left failure -> pure (Left (refusal failure))
                    Right row -> do
                        native <- observeNative description
                        after <- inEntry (\protected -> validateRootedProbePrerequisiteInEntryKernel protected identity row)
                        pure $ case (native, after) of
                            (Left failure, _) -> Left (refusal ("the cluster did not report the declared object: " <> failure))
                            (_, Left failure) -> Left (refusal failure)
                            (Right reported, Right ()) -> Right (RootedClusterObjectObservation identity description row reported)
  where
    inEntry :: (forall session. ProtectedSession session -> IO (Either Text value)) -> IO (Either Text value)
    inEntry action = do
        entered <- withProtectedEntry store (fmap Right . action)
        pure $ case entered of
            Left failure -> Left (protectedErrorMessage failure)
            Right inner -> inner
    refusal cause = "rooted cluster object observation: " <> cause

{- | Reobserve the same identity rather than trusting the previous result: the
record must still be the bound one and the native identity, including its
conditional version, must be unchanged.
-}
recheckRootedClusterObjectKernel ::
    Eq native =>
    ProtectedStore ->
    ProjectPlan scope specDigest planId configId cfg ->
    RootedClusterObjectObservation native ->
    (ClusterObjectProbeDescription -> IO (Either Text native)) ->
    IO (Either Text ())
recheckRootedClusterObjectKernel store plan (RootedClusterObjectObservation identity _ row expected) observeNative = do
    observed <- observeRootedClusterObjectKernel store plan identity observeNative
    pure $ do
        RootedClusterObjectObservation _ _ currentRow actual <- observed
        if not (sameRow currentRow row)
            then Left "rooted cluster object recheck: the bound record changed"
            else
                if actual == expected
                    then Right ()
                    else Left "rooted cluster object recheck: the cluster object's identity or version changed"
  where
    sameRow (RootedResourceObservation storeA keyA versionA bytesA) (RootedResourceObservation storeB keyB versionB bytesB) =
        storeA == storeB && keyA == keyB && versionA == versionB && bytesA == bytesB

-- | Recover the owned generation only from the exact, still-current root row.
-- This is descriptive input to a native probe, not a readiness observation.
observeRootedProviderGenerationInEntryKernel ::
    ProtectedSession session -> RootProbeIdentity -> RootedResourceObservation -> IO (Either Text Word64)
observeRootedProviderGenerationInEntryKernel = observeRootedGenerationInEntryKernel RootProviderProbe "provider"

-- | Read the exact owned share generation without preparing a mutation.
observeRootedShareGenerationInEntryKernel ::
    ProtectedSession session -> RootProbeIdentity -> RootedResourceObservation -> IO (Either Text Word64)
observeRootedShareGenerationInEntryKernel = observeRootedGenerationInEntryKernel RootDurableShareProbe "durable share"

observeRootedGenerationInEntryKernel ::
    RootProbeFamily -> Text -> ProtectedSession session -> RootProbeIdentity -> RootedResourceObservation -> IO (Either Text Word64)
observeRootedGenerationInEntryKernel family label protected identity observation@(RootedResourceObservation _ _ _ bytes)
    | rootProbeIdentityFamilyKernel identity /= family =
        pure (Left ("rooted " <> label <> " observation: resource has the wrong family"))
    | otherwise = do
        current <- validateRootedProbePrerequisiteInEntryKernel protected identity observation
        pure $ do
            current
            bundle <- verifyExactResourceRecordBundleKernel plan frame operation bytes
            withVerifiedResourceRecordBundleKernel bundle
                (\_ generation _ -> Right generation)
                (\_ _ _ _ _ _ _ -> Left ("rooted " <> label <> " observation: resource is released"))
  where
    (plan, frame, operation, _) = rootProbeIdentityCoordinatesKernel identity

-- | Read descriptive bytes for the gate's exact resource under an already-held entry.
readRootedResourcePredecessorInEntryKernel :: ProtectedSession session -> Text -> Text -> Text -> IO (Either Text (Maybe ByteString))
readRootedResourcePredecessorInEntryKernel protected frame plan operation =
    case resourceRecordKeyKernel plan frame operation >>= either (Left . protectedErrorMessage) Right . mkRecordKey of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord protected key
            pure $ case observed of
                Left failure -> Left (protectedErrorMessage failure)
                Right Nothing -> Right Nothing
                Right (Just record) -> do
                    let bytes = protectedRecordBytes record
                    _ <- verifyExactResourceRecordBundleKernel plan frame operation bytes
                    Right (Just bytes)

-- | Expose only the exact predecessor after checking the live prepared gate.
withRootedPreparedResourcePredecessorKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text -> (Maybe ByteString -> IO (Either Text ())) -> IO (Either Text ())
withRootedPreparedResourcePredecessorKernel journal frameSession operation use =
    withRootedFrameSessionKernel frameSession $ \attached _ _ _ frame _ _ _ _ _ ->
        if not attached then pure (Left "rooted operation journal: predecessor requires an attached frame") else do
            selected <- withRootedOperationJournalKernel journal $ \store epoch session _fence permit pending ->
                case lookup operation pending of
                    Nothing -> pure (Left "rooted operation journal: predecessor has no prepared gate")
                    Just gate -> do
                        entered <- withProtectedEntry store $ \protected -> do
                            live <- validateAllocatedBrokerEpochKernel protected epoch
                            case live of
                                Left failure -> pure (Right (Left (Text.pack (show failure))))
                                Right () -> do
                                    valid <- validatePreparedGateForSettlementKernel protected session gate permit
                                    case valid of
                                        Left failure -> pure (Right (Left (Text.pack (sessionErrorMessage failure))))
                                        Right () -> Right <$> readRootedResourcePredecessorInEntryKernel protected frame (preparedGatePlan gate) (preparedGateOperation gate)
                        pure $ case entered of
                            Left failure -> Left (Text.pack (show failure))
                            Right (Left failure) -> Left failure
                            Right (Right predecessor) -> Right (permit, pending, predecessor)
            either (pure . Left) use selected

{- | One root-owned frame session through its two durable states.

Opened retains the root-selected coordinates and the exact durable row they
were published as. Attached nests that exact opening with the admitted nonce,
the first predecessor digest, and its own successor row. Neither constructor
retains a store, catalog, runtime, request, or response value: what escapes an
elimination is coordinates, and coordinates authorize nothing.
-}
data
    RootedFrameSession
        scope
        rootPlanId
        brokerGeneration
        catalogId
        frame
        sessionId
        verb
    where
    OpenedRootedFrameSession ::
        OpenedFrameFields verb ->
        RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb
    AttachedRootedFrameSession ::
        OpenedFrameFields verb ->
        ByteString ->
        Text ->
        RecordVersion ->
        ByteString ->
        RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb

-- A durable opening is retained directly, so an attachment cannot nest another attachment.
data OpenedFrameFields verb = OpenedFrameFields
    (ProjectVerb verb) Text Text Text [Text] Text Text Word64 RecordKey RecordVersion ByteString

type role RootedFrameSession nominal nominal nominal nominal nominal nominal nominal

instance Show (RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb) where
    show OpenedRootedFrameSession{} = "RootedFrameSession <opened>"
    show AttachedRootedFrameSession{} = "RootedFrameSession <attached>"

{- | Open one root-owned session for an exact catalog frame.

Nothing here is caller-selected. The requester path is the catalog's own
descent chain to this frame, the session token is a digest of the root lineage,
catalog identity, frame, verb, opening mode, and requester path — opaque, and stable so that reopening
converges rather than forking — the stage is the fixed initial one, and the
next ordinal is the first nonzero one. The record key is derived from root
lineage, catalog identity, frame, and opening mode.

The runtime is checked before the store is opened, and it must be the root arm:
a keyless nested arm cannot open a session, which is what keeps journal
ownership at the topology root. The published row carries no
predecessor-response digest, because at this point nothing has been answered.

Both the frame and session indices are existential, so a caller cannot name the
type of one frame's session and be handed another's — the indices are minted by
the opening rather than chosen by whoever asked for it.
-}
withRootOpenedFrameSessionKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    ProtectedStore ->
    ProjectVerb verb ->
    Text ->
    ( forall frame sessionId.
      RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withRootOpenedFrameSessionKernel #-}
withRootOpenedFrameSessionKernel runtime catalog store verb requestedFrame use =
    withRootOpenedFrameSessionPathKernel False runtime catalog store verb requestedFrame use

-- | Open a session for a reverse child launched directly by the root owner.
withRootOpenedDirectFrameSessionKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    ProtectedStore ->
    ProjectVerb verb ->
    Text ->
    ( forall frame sessionId.
      RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withRootOpenedDirectFrameSessionKernel runtime catalog store verb requestedFrame use =
    withRootOpenedFrameSessionPathKernel True runtime catalog store verb requestedFrame use

withRootOpenedFrameSessionPathKernel ::
    Bool ->
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    ProtectedStore ->
    ProjectVerb verb ->
    Text ->
    ( forall frame sessionId.
      RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withRootOpenedFrameSessionPathKernel direct runtime catalog store verb requestedFrame use =
    withRecursiveHandoffRuntimeKernel runtime $ \atRoot _project _tag _store generation runtimeVerb _keyDigest frame ->
        case admit atRoot generation runtimeVerb frame of
            Left failure -> pure (Left failure)
            Right (path, key, opened) -> do
                entered <- withProtectedEntry store $ \session ->
                    Right <$> openOrRestartDirect session path key opened
                case entered of
                    Left failure -> refused (Text.pack (show failure))
                    Right (Left failure) -> refused failure
                    Right (Right (version, present))
                        | present /= opened ->
                            refused "the durable rooted frame session row is not this opening"
                        | otherwise ->
                            use
                                ( OpenedRootedFrameSession
                                    ( OpenedFrameFields
                                    verb
                                    rootPlanDigest
                                    catalogIdentity
                                    requestedFrame
                                    path
                                    (sessionTokenFor path)
                                    openingStage
                                    initialOrdinal
                                    key
                                    version
                                    opened
                                    )
                                )
  where
    catalogIdentity = rootedPlanCatalogRecordIdentityKernel catalog
    rootPlanDigest = withRootedPlanCatalogRootKernel catalog (\_ _ plan _ _ -> stablePlanSnapshotDigest (renderSnapshot plan))
    verbName = projectVerbName verb
    -- The root itself settles an Up frame its own catalog proves empty; every
    -- other frame opens unsettled and advances only through its work.
    openingStage
        | verbName == "up" && either (const False) (const True) (rootedEmptyFrameProofKernel catalog requestedFrame) = "settled"
        | otherwise = initialStage

    admit atRoot generation runtimeVerb frame = do
        require "a keyless nested arm cannot open a root frame session" atRoot
        require "the runtime is not path-agnostic" (isNothing frame)
        require "the runtime verb differs from the session verb" (runtimeVerb == verbName)
        require "the broker generation is zero" (generation > 0)
        require "the root plan digest is empty" (not (Text.null rootPlanDigest))
        require "the catalog identity is empty" (not (Text.null catalogIdentity))
        path <- canonicalRequesterPath
        require "the root frame has no rooted requester path" (not (null path))
        key <- sessionFailure ((if direct then rootedDirectFrameSessionKeyKernel else rootedFrameSessionKeyKernel) rootPlanDigest catalogIdentity requestedFrame)
        let opened = renderOpenedRow path
        require
            "the rooted frame session row exceeds the durable bound"
            (fromIntegral (ByteString.length opened) <= maxWireBytes)
        pure (path, key, opened)

    {- The catalog's own descent chain to this frame, root-nearest-to-leaf —
    the exact order a sealed external relay envelope is built in, where every
    serving hop prepends its own current frame before forwarding. The root
    itself never appears, because it is the endpoint rather than a hop. Every
    component comes from an admitted descent edge, so a frame no edge names, a
    frame two edges name, and a chain that walks more levels than the catalog
    holds all refuse: a caller can name a frame and be told the one path that
    frame has, and can neither order nor extend it. -}
    canonicalRequesterPath
        | direct = case [parent | (parent, child) <- edges, child == requestedFrame] of
            _ | requestedFrame == rootFrame -> Left (rootedFailure "the root frame has no rooted requester path")
            [_] -> Right [requestedFrame]
            [] -> Left (rootedFailure "no admitted descent edge names the requested frame")
            _ -> Left (rootedFailure "more than one admitted descent edge names the requested frame")
        | otherwise = climb (length edges) requestedFrame []
      where
        edges =
            withRootedPlanCatalogEntriesKernel
                catalog
                (\_plan _binding _current (ParentFrameId parent) (ChildFrameId child) _raw _route _payload _config _payload' _keys -> (parent, child))
        rootFrame = withRootedPlanCatalogRootKernel catalog (\_ _ _ current _ -> currentFrameId current)
        climb remaining frame path
            | frame == rootFrame = Right path
            | remaining <= (0 :: Int) =
                Left (rootedFailure "the admitted descent chain does not reach the root frame")
            | otherwise = case [parent | (parent, child) <- edges, child == frame] of
                [parent] -> climb (remaining - 1) parent (frame : path)
                [] -> Left (rootedFailure "no admitted descent edge names the requested frame")
                _ -> Left (rootedFailure "more than one admitted descent edge names the requested frame")

    sessionTokenFor path =
        childConfigDigest
            ( ByteString.concat
                ( [ framedText "hostbootstrap/rooted-frame-session-token"
                  , framedWord 2
                  , framedText (if direct then "direct" else "canonical")
                  , framedText rootPlanDigest
                  , framedText catalogIdentity
                  , framedText requestedFrame
                  , framedText verbName
                  , framedWord (fromIntegral (length path))
                  ]
                    ++ map framedText path
                )
            )

    renderOpenedRow path =
        ByteString.concat
            ( [ framedText rootedFrameSessionDomain
              , framedWord 1
              , framedText "opened"
              , framedText rootPlanDigest
              , framedText catalogIdentity
              , framedText requestedFrame
              , framedText verbName
              , framedText (sessionTokenFor path)
              , framedText openingStage
              , framedWord initialOrdinal
              , framedWord (fromIntegral (length path))
              ]
                ++ map framedText path
            )

    openOrRestartDirect ::
        forall session.
        ProtectedSession session ->
        [Text] ->
        RecordKey ->
        ByteString ->
        IO (Either Text (RecordVersion, ByteString))
    openOrRestartDirect session path key opened = do
        observed <- openRootedFrameSessionRecordKernel session key opened
        case observed of
            Left failure -> pure (Left (Text.pack (sessionErrorMessage failure)))
            Right exact@(_version, present)
                | present == opened -> pure (Right exact)
            Right (version, present)
                | direct
                , Right () <-
                    validateAttachedRootedFrameSessionRow
                        rootPlanDigest
                        catalogIdentity
                        path
                        opened
                        present -> do
                    current <- readProtectedRecord session key
                    case current of
                        Left failure -> pure (Left (Text.pack (show failure)))
                        Right (Just record)
                            | protectedRecordVersion record == version
                            , protectedRecordBytes record == present -> do
                                deleted <-
                                    compareAndDeleteProtectedRecord
                                        session
                                        key
                                        (ExpectVersion version)
                                case deleted of
                                    Left failure -> pure (Left (Text.pack (show failure)))
                                    Right () -> do
                                        restarted <- openRootedFrameSessionRecordKernel session key opened
                                        pure $ case restarted of
                                            Left failure -> Left (Text.pack (sessionErrorMessage failure))
                                            Right exact@(_restartedVersion, restartedBytes)
                                                | restartedBytes == opened -> Right exact
                                                | otherwise -> Left "the restarted rooted frame session differs from this opening"
                        _ -> pure (Left "the abandoned rooted frame session changed before restart")
            Right _ -> pure (Left "the durable rooted frame session row is not this opening")

    refused = pure . Left . rootedFailure

{- | Cancel an exact session which never crossed the attachment boundary.

The durable kernel rechecks the opening's version and bytes under the store
lock. Attached sessions refuse here and remain subject to terminal-report
recovery.
-}
cancelUnattachedRootedFrameSessionKernel ::
    ProtectedStore ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    IO (Either Text ())
cancelUnattachedRootedFrameSessionKernel store session =
    case session of
        OpenedRootedFrameSession (OpenedFrameFields _ _ _ _ _ _ _ _ key version opened) -> do
            cancelled <- withProtectedEntry store $ \protected ->
                Right <$> cancelOpenedRootedFrameSessionRecordKernel protected key version opened
            pure $ case cancelled of
                Left failure -> Left (rootedFailure (Text.pack (show failure)))
                Right (Left failure) -> Left (rootedFailure (Text.pack (sessionErrorMessage failure)))
                Right (Right ()) -> Right ()
        AttachedRootedFrameSession{} ->
            pure (Left (rootedFailure "an attached frame session cannot be cancelled as unused"))

{- | Attach one exact 'OpenFrame' to an already opened session, or replay it.

Everything is resolved before a byte is written. The runtime must still be the
root arm, the sealed external envelope path must equal the path the session
itself retains, and the request must decode as exactly an @OpenFrame@ — whose
only field is its nonce. A post-open request form cannot attach at all.

The replay identity is the attached row itself, and that row frames root
lineage, catalog identity, envelope path, and nonce together. Two attachments
therefore collide only when all four agree, so the same nonce under a different
lineage, catalog, or path is a different attachment rather than a replay of
this one.

The predecessor is the lowercase SHA-256 digest of the complete signed @Opened@
bytes as supplied — this module neither produces nor signs a response, and the
digest it records is of bytes it was handed rather than bytes it chose.
-}
withAttachedRootedFrameSessionKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ProtectedStore ->
    [Text] ->
    ByteString ->
    ByteString ->
    ( RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withAttachedRootedFrameSessionKernel #-}
withAttachedRootedFrameSessionKernel runtime opened store envelope request signedOpened use =
    case opened of
        AttachedRootedFrameSession{} ->
            pure (Left (rootedFailure "the rooted frame session is already attached"))
        OpenedRootedFrameSession fields@(OpenedFrameFields _ rootPlanDigest catalogIdentity _ path _ _ _ key version openedBytes) ->
            withRecursiveHandoffRuntimeKernel runtime $ \atRoot _project _tag _store _generation _verb _keyDigest frame ->
                case admit atRoot frame path rootPlanDigest catalogIdentity openedBytes of
                    Left failure -> pure (Left failure)
                    Right (nonce, predecessor, attached) -> do
                        entered <- withProtectedEntry store $ \session ->
                            Right
                                <$> attachRootedFrameSessionRecordKernel
                                    session
                                    key
                                    version
                                    openedBytes
                                    attached
                        case entered of
                            Left failure -> refused (Text.pack (show failure))
                            Right (Left failure) -> refused (Text.pack (sessionErrorMessage failure))
                            Right (Right attachedVersion) ->
                                use
                                    ( AttachedRootedFrameSession
                                        fields
                                        nonce
                                        predecessor
                                        attachedVersion
                                        attached
                                    )
  where
    admit atRoot frame path rootPlanDigest catalogIdentity openedBytes = do
        require "a keyless nested arm cannot attach a root frame session" atRoot
        require "the runtime is not path-agnostic" (isNothing frame)
        require "the sealed external envelope is not the session's own path" (envelope == path)
        require "the signed Opened response is empty" (not (ByteString.null signedOpened))
        require
            "the signed Opened response exceeds the durable bound"
            (fromIntegral (ByteString.length signedOpened) <= maxWireBytes)
        decoded <- either (Left . rootedFailure) Right (rootedLifecycleRequestFromWireKernel request)
        nonce <-
            withRootedLifecycleRequestKernel
                decoded
                Right
                (\_ _ _ _ _ _ -> postOpen)
                (\_ _ _ _ _ _ _ -> postOpen)
                (\_ _ _ _ _ _ _ -> postOpen)
                (\_ _ _ _ _ _ -> postOpen)
                (\_ _ _ _ _ _ -> postOpen)
        let predecessor = childConfigDigest signedOpened
            attached =
                renderAttachedRootedFrameSessionRow
                    rootPlanDigest
                    catalogIdentity
                    path
                    openedBytes
                    nonce
                    (TextEncoding.encodeUtf8 predecessor)
        require
            "the attached rooted frame session row exceeds the durable bound"
            (fromIntegral (ByteString.length attached) <= maxWireBytes)
        pure (nonce, predecessor, attached)

    postOpen = Left (rootedFailure "only an OpenFrame request attaches a rooted frame session")

    refused = pure . Left . rootedFailure

{- | Answer one exact 'OpenFrame' from the session the root already opened.

This is the join the live root endpoint stands on, and every value in the
answer comes from the left of it. The requester supplies an envelope and a
nonce; the session supplies the admitted canonical path, the opaque token, the
stage, and the next ordinal; and the response names the request only by the
digest of the exact bytes that arrived. Nothing a requester sent selects a
coordinate.

The envelope is checked as a grammar before it is checked as an identity, and
the grammar is the post-open request codec's own: one to 256 components, none
empty, none wider than 4,096 encoded bytes. A path that is malformed is refused
on those terms rather than compared, so an oversized or empty component never
reaches the session comparison at all. Only then must it equal the path this
session retains.

Signing is a continuation because this module cannot sign. It renders the exact
nine-field unsigned @Opened@, hands those bytes out, and takes back the
complete signed response; the durable attachment then records that response's
digest and reads it back before the caller may release it. So the order is
fixed in the one direction that matters — no answer leaves the root before the
root durably holds what it answered.

An already attached session refuses here rather than opening a second exchange,
and a post-open request form cannot reach this path at all, because the
attachment it delegates to admits only an @OpenFrame@.
-}
withRootedFrameOpeningKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ProtectedStore ->
    [Text] ->
    ByteString ->
    (ByteString -> IO (Either Text ByteString)) ->
    ( RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
      ByteString ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withRootedFrameOpeningKernel #-}
withRootedFrameOpeningKernel runtime session store envelope request sign use =
    withRootArmRecursiveHandoffRuntimeKernel runtime $
        \_project _tag _store generation _runtimeVerb _keyDigest ->
            withRootedFrameSessionKernel session $
                \attached _verb _lineage catalogIdentity _frame path token stage ordinal _predecessor ->
                    case admit attached generation catalogIdentity path token stage ordinal of
                        Left failure -> pure (Left failure)
                        Right unsigned -> do
                            signed <- sign unsigned
                            case signed of
                                Left failure -> pure (Left failure)
                                Right signedOpened ->
                                    case validateSignedOpening unsigned signedOpened of
                                        Left failure -> pure (Left failure)
                                        Right () ->
                                            withAttachedRootedFrameSessionKernel
                                                runtime
                                                session
                                                store
                                                envelope
                                                request
                                                signedOpened
                                                (\opened -> use opened signedOpened)
  where
    admit attached generation catalogIdentity path token stage ordinal = do
        require "an attached rooted frame session cannot answer a second opening" (not attached)
        require "the broker generation is zero" (generation > 0)
        require "the catalog identity is empty" (not (Text.null catalogIdentity))
        requireEnvelopeGrammar
        require "the sealed external envelope is not the session's own path" (envelope == path)
        decoded <- either (Left . rootedFailure) Right (rootedLifecycleRequestFromWireKernel request)
        _ <-
            withRootedLifecycleRequestKernel
                decoded
                Right
                (\_ _ _ _ _ _ -> postOpenOpening)
                (\_ _ _ _ _ _ _ -> postOpenOpening)
                (\_ _ _ _ _ _ _ -> postOpenOpening)
                (\_ _ _ _ _ _ -> postOpenOpening)
                (\_ _ _ _ _ _ -> postOpenOpening)
        either
            (Left . rootedFailure)
            Right
            (rootedOpenedResponseUnsignedKernel (childConfigDigest request) path token stage ordinal)

    validateSignedOpening unsigned signedOpened = do
        response <- either (Left . rootedFailure) Right (rootedLifecycleResponseFromWireKernel signedOpened)
        isOpened <- withRootedLifecycleResponseKernel response
            (\_ _ _ _ _ _ -> Right True)
            (\_ _ _ _ _ _ _ _ _ _ _ -> Right False)
            (\_ _ _ _ _ _ _ _ -> Right False)
            (\_ _ _ _ _ _ _ _ -> Right False)
            (\_ _ _ _ _ _ _ _ -> Right False)
            (\_ _ _ _ _ _ _ _ -> Right False)
            (\_ _ _ _ _ _ _ _ -> Right False)
        require "the signed opening is not an Opened response" isOpened
        require "the signed opening differs from the rendered Opened response"
            (renderRootedLifecycleUnsignedResponseKernel response == unsigned)

    {- The sealed external ancestry uses the same grammar as the post-open
    inner path, and it is enforced before the identity comparison so a
    malformed envelope is refused on its own terms. -}
    requireEnvelopeGrammar = do
        require "the sealed external envelope is empty" (not (null envelope))
        require
            "the sealed external envelope exceeds the requester path depth"
            (length envelope <= maxRootedRequesterComponents)
        require
            "the sealed external envelope contains an empty component"
            (not (any Text.null envelope))
        require
            "the sealed external envelope contains an oversized component"
            ( all
                ( (<= maxRootedRequesterComponentBytes)
                    . ByteString.length
                    . TextEncoding.encodeUtf8
                )
                envelope
            )

    postOpenOpening =
        Left (rootedFailure "only an OpenFrame request opens a rooted frame exchange")

{- | Read one session's root-selected coordinates without opening a route.

The continuation receives whether this session has attached, its verb, root
lineage, catalog identity, frame, canonical requester path, opaque session
token, stage, next ordinal, and the first predecessor digest once one exists.
It receives no store, key, record version, catalog, runtime, request, or
response, and its result is fixed.
-}
withRootedFrameSessionKernel ::
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ( Bool ->
      Text ->
      Text ->
      Text ->
      Text ->
      [Text] ->
      Text ->
      Text ->
      Word64 ->
      Maybe Text ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withRootedFrameSessionKernel #-}
withRootedFrameSessionKernel session use = case session of
    OpenedRootedFrameSession (OpenedFrameFields verb lineage catalogIdentity frame path token stage ordinal _ _ _) ->
        use False (projectVerbName verb) lineage catalogIdentity frame path token stage ordinal Nothing
    AttachedRootedFrameSession
        (OpenedFrameFields verb lineage catalogIdentity frame path token stage ordinal _ _ _)
        _
        predecessor
        _
        _ ->
            use True (projectVerbName verb) lineage catalogIdentity frame path token stage ordinal (Just predecessor)

{- | Eliminate only an attached Up session whose last root-issued successor is
the closed refusal stage or a durably acknowledged terminal receipt. The
continuation receives descriptive coordinates;
it receives no session constructor, store, request, or mutation capability.
-}
withFailedRootedFrameSessionKernel ::
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    (Text -> Text -> Text -> [Text] -> Text -> Word64 -> result) ->
    Either Text result
withFailedRootedFrameSessionKernel session use =
    case session of
        AttachedRootedFrameSession
            (OpenedFrameFields verb lineage catalog frame path token stage ordinal _ _ _)
            _
            _
            _
            _
                | projectVerbName verb /= "up" -> refused "the failed session is not an Up session"
                | stage `notElem` ["refused", "frame-complete", "receipt-recorded"] -> refused "the failed session has not reached a terminal failure stage"
                | otherwise -> Right (use lineage catalog frame path token ordinal)
        OpenedRootedFrameSession{} -> refused "the failed session was never attached"
  where
    refused = Left . rootedFailure

{- | Advance the in-memory conversation only from one exact paired response.

Durable node/terminal owners publish their rows before calling this kernel.
The successor therefore carries no mutation capability: it merely retains the
stage, ordinal, and predecessor digest the root's own canonical response chose.
-}
withAdvancedRootedFrameSessionKernel ::
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ByteString ->
    ByteString ->
    ( RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withAdvancedRootedFrameSessionKernel session request signedResponse use =
    case session of
        OpenedRootedFrameSession{} ->
            pure (Left (rootedFailure "an unattached frame session cannot advance"))
        AttachedRootedFrameSession (OpenedFrameFields verb lineage catalog frame path token currentStage ordinal key version openedBytes) nonce _ attachedVersion attachedBytes ->
            case advanced currentStage path token ordinal of
                Left failure -> pure (Left failure)
                Right (stage, successor) ->
                    use
                        ( AttachedRootedFrameSession
                            (OpenedFrameFields verb lineage catalog frame path token stage successor key version openedBytes)
                            nonce
                            (childConfigDigest signedResponse)
                            attachedVersion
                            attachedBytes
                        )
  where
    advanced currentStage path token ordinal = do
        require "a terminal rooted frame session cannot advance" (currentStage `notElem` ["refused", "receipt-recorded"])
        response <- either (Left . rootedFailure) Right (rootedLifecycleResponseFromWireKernel signedResponse)
        (digest, responsePath, responseSession, stage, successor) <-
            withRootedLifecycleResponseKernel
                response
                (\_ _ _ _ _ _ -> outside)
                (\d p s st o _ _ _ _ _ _ -> Right (d, p, s, st, o))
                (\d p s st o _ _ _ -> Right (d, p, s, st, o))
                (\d p s st o _ _ _ -> Right (d, p, s, st, o))
                (\d p s st o _ _ _ -> Right (d, p, s, st, o))
                (\d p s st o _ _ _ -> Right (d, p, s, st, o))
                (\d p s st o _ _ _ -> Right (d, p, s, st, o))
        require "the response answers another request" (digest == childConfigDigest request)
        require "the response echoes another requester path" (responsePath == path)
        require "the response echoes another session" (responseSession == token)
        require "the response does not advance the ordinal by exactly one" (ordinal < maxBound && successor == ordinal + 1)
        pure (stage, successor)
    outside = Left (rootedFailure "an Opened response cannot advance an attached frame session")

{- | Recognize only the exact attached successor of one known opening.

This parser is deliberately narrower than a general session-row decoder. It is
used only when a new, mode-exclusive reverse invocation finds the transport
exchange left by its dead predecessor. Durable node and terminal rows carry
the lifecycle progress; the attached row carries only the now-unusable child
nonce and response predecessor. A canonical exact successor may therefore be
removed and reopened atomically, while an ordinary forward opening, a foreign
opening, malformed framing, or a changed row still refuses.
-}
validateAttachedRootedFrameSessionRow ::
    Text ->
    Text ->
    [Text] ->
    ByteString ->
    ByteString ->
    Either Text ()
validateAttachedRootedFrameSessionRow rootPlanDigest catalogIdentity path openedBytes raw = do
    (domain, afterDomain) <- takeAttachedField raw
    (version, afterVersion) <- takeAttachedField afterDomain
    (stage, afterStage) <- takeAttachedField afterVersion
    (opening, afterOpening) <- takeAttachedField afterStage
    (lineage, afterLineage) <- takeAttachedField afterOpening
    (catalog, afterCatalog) <- takeAttachedField afterLineage
    (componentCount, afterComponentCount) <- takeAttachedField afterCatalog
    afterPath <- takeAttachedPath path afterComponentCount
    (nonce, afterNonce) <- takeAttachedField afterPath
    (predecessor, trailing) <- takeAttachedField afterNonce
    require
        "the attached rooted frame session domain differs"
        (domain == TextEncoding.encodeUtf8 rootedFrameSessionDomain)
    require "the attached rooted frame session version differs" (version == wordBytes 1)
    require "the rooted frame session is not attached" (stage == "attached")
    require "the attached rooted frame session nests another opening" (opening == openedBytes)
    require
        "the attached rooted frame session has another root plan"
        (lineage == TextEncoding.encodeUtf8 rootPlanDigest)
    require
        "the attached rooted frame session has another catalog"
        (catalog == TextEncoding.encodeUtf8 catalogIdentity)
    require
        "the attached rooted frame session path count differs"
        (componentCount == wordBytes (fromIntegral (length path)))
    require "the attached rooted frame session nonce is empty" (not (ByteString.null nonce))
    require
        "the attached rooted frame session predecessor is not a digest"
        (isLowerHexDigest predecessor)
    require "the attached rooted frame session has trailing bytes" (ByteString.null trailing)

takeAttachedPath :: [Text] -> ByteString -> Either Text ByteString
takeAttachedPath [] rest = Right rest
takeAttachedPath (expected : remaining) raw = do
    (component, rest) <- takeAttachedField raw
    require
        "the attached rooted frame session path differs"
        (component == TextEncoding.encodeUtf8 expected)
    takeAttachedPath remaining rest

takeAttachedField :: ByteString -> Either Text (ByteString, ByteString)
takeAttachedField =
    either
        (Left . rootedFailure . Text.pack . handoffErrorMessage)
        Right
        . takeHandoffFrame

renderAttachedRootedFrameSessionRow ::
    Text ->
    Text ->
    [Text] ->
    ByteString ->
    ByteString ->
    ByteString ->
    ByteString
renderAttachedRootedFrameSessionRow rootPlanDigest catalogIdentity path openedBytes nonce predecessor =
    ByteString.concat
        ( [ framedText rootedFrameSessionDomain
          , framedWord 1
          , framedText "attached"
          , frameWire openedBytes
          , framedText rootPlanDigest
          , framedText catalogIdentity
          , framedWord (fromIntegral (length path))
          ]
            ++ map framedText path
            ++ [frameWire nonce, frameWire predecessor]
        )

wordBytes :: Word64 -> ByteString
wordBytes = LazyByteString.toStrict . Builder.toLazyByteString . Builder.word64BE

isLowerHexDigest :: ByteString -> Bool
isLowerHexDigest digest =
    ByteString.length digest == 64
        && ByteString.all
            (\byte -> (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102))
            digest

rootedFrameSessionDomain :: Text
rootedFrameSessionDomain = "hostbootstrap/rooted-frame-session"

initialStage :: Text
initialStage = "open"

{- | Root-owned proof that the exact catalog-selected frame has no work: its one
catalog entry's admitted plan places no forward node in it and gives it no
descent. A forged or ambiguous selection, or any nonempty frame, refuses.
-}
rootedEmptyFrameProofKernel ::
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId -> Text -> Either Text ()
rootedEmptyFrameProofKernel catalog frame =
    case [ empty
         | (child, empty) <- withRootedPlanCatalogEntriesKernel catalog (\plan _ _ _ (ChildFrameId child) _ _ _ _ _ _ ->
            ( child
            , all ((/= child) . plannedStepFrameIdKernel) (forwardKernel plan)
                && case topologyDescentFromKernel (topologyKernel plan) child of
                    Nothing -> True
                    Just _ -> False
            ))
         , child == frame
         ] of
        [True] -> Right ()
        [False] -> Left "the catalog-selected frame has admitted work"
        _ -> Left "the frame is not exactly one catalog entry"

initialOrdinal :: Word64
initialOrdinal = 1

maxRootedRequesterComponents :: Int
maxRootedRequesterComponents = 256

maxRootedRequesterComponentBytes :: Int
maxRootedRequesterComponentBytes = 4096

framedText :: Text -> ByteString
framedText = frameWire . TextEncoding.encodeUtf8

framedWord :: Word64 -> ByteString
framedWord = frameWire . wordBytes

sessionFailure :: Either SessionError result -> Either Text result
sessionFailure = either (Left . rootedFailure . Text.pack . sessionErrorMessage) Right

require :: Text -> Bool -> Either Text ()
require _ True = Right ()
require detail False = Left (rootedFailure detail)

rootedFailure :: Text -> Text
rootedFailure detail = "rooted frame session: " <> detail
