{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | What the root authorizes and settles for one node of one frame session.

The frame session owner holds the durable row a session *is*. This module holds
what happens inside one: preparing the exact node grant a storeless executor
needs, and settling the observation that comes back. Splitting them is not
bookkeeping — it is the boundary. This module reaches a session only through
its fixed-unit coordinate fold, so it never sees the session's record key,
version, or row bytes and cannot advance or rewrite the session itself. It
derives its own keys from the coordinates it is shown, and every row it writes
is its own.

Both operations are durable-first. A grant does not exist until every exact
unknown row is published and read back; a settlement does not exist until the
observation row is published and read back. Neither produces or signs a
response — the signed bytes are supplied, and the live root endpoint owns
producing them — so no answer can be manufactured here to match a decision
already taken.
-}
module HostBootstrap.Lifecycle.Rooted.Node (
    RootedCleanupLease,
    acquireRootedCleanupLeaseKernel,
    withRootedCleanupLeaseForPredecessorKernel,
    releaseRootedCleanupLeaseKernel,
    withJournalPreparedRootedNodeGrantKernel,
    withJournalPreparedRootedEffectNodeGrantKernel,
    withRootedFrameJournalKernel,
    withSettledRootedNodeKernel,
)
where

import Control.Concurrent (forkFinally, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, displayException, mask, onException)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (nub)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority (RootInvocationAuthority, brokerEpochWord, projectVerbName, rootAuthorityEpoch, rootAuthorityProjectName, rootAuthorityVerb)
import HostBootstrap.Authority.Kernel (rootAuthorityStoreIdentity, validateAllocatedBrokerEpochKernel)
import HostBootstrap.Handoff (childConfigDigest, frameWire)
import HostBootstrap.Handoff.Rooted (
    renderReversePreparedGateEnvelopeKernel,
    rootedLifecycleRequestFromWireKernel,
    rootedLifecycleResponseFromWireKernel,
    withRootedLifecycleRequestKernel,
    withRootedLifecycleResponseKernel,
 )
import HostBootstrap.Handoff.Runtime (
    RecursiveHandoffRuntime,
    withRecursiveHandoffRuntimeKernel,
 )
import HostBootstrap.Lifecycle.Prepared.Internal (
    PreparedNodeGrant,
    mintPreparedNodeGrantKernel,
    preparedGateOperation,
    preparedGatePlan,
    renderPreparedGatePackagesKernel,
 )
import HostBootstrap.Lifecycle.Rooted (
    RootedFrameSession,
    RootedOperationJournal,
    checkRootedSettlementRowKernel,
    rootedSettlementSessionTokenKernel,
    selectRootedSettlementAddressKernel,
    publishRootedSettlementExactKernel,
    RootedResourceObservation,
    prepareRootedOperationJournalForPrerequisitesKernel,
    prepareRootedEffectJournalForPrerequisitesKernel,
    validateRootedJournalCoordinatesKernel,
    packageRootedJournalGateKernel,
    readRootedResourcePredecessorInEntryKernel,
    withRootedFrameSessionKernel,
    withRootedOperationJournalKernel,
 )
import HostBootstrap.Lifecycle.Plan (RootProbeIdentity)
import HostBootstrap.Lifecycle.RootedPlan (ChildFrameId (ChildFrameId), RootedPlanCatalog, rootedPlanCatalogRecordIdentityKernel, withRootedPlanCatalogEntriesKernel, withRootedPlanCatalogRootKernel)
import HostBootstrap.Lifecycle.Session (
    FenceEpoch,
    OperationSession,
    ProjectPermit,
    establishInitialFence, fenceEpochWord,
    openOperationSession,
    openProjectJournal,
    rootedSettlementKeyKernel,
    sessionErrorMessage, validatePreparedGateForSettlementKernel,
 )
import HostBootstrap.ProjectPlan (ProjectPlan, renderSnapshot, stablePlanSnapshotDigest)
import HostBootstrap.ProjectPlan.Frame (currentFrameId)
import HostBootstrap.Protected (ProtectedSession, ProtectedStore, RecordKey, protectedStoreIdentity, protectedStoreIdentityText, withProtectedEntry)

{- | A root lock retained only while one admitted remote cleanup is in flight.

The worker holds the journal permit and the same protected entry that fence
supersession must enter. It validates the exact prepared gate inside that entry
before the caller can send the grant. Release is idempotent and waits for the
entry to be unlocked; an interrupted acquisition also releases the worker.
-}
data RootedCleanupLease scope rootPlanId brokerGeneration catalogId frame sessionId verb =
    RootedCleanupLease (MVar ()) (MVar (Either Text ()))

type role RootedCleanupLease nominal nominal nominal nominal nominal nominal nominal

acquireRootedCleanupLeaseKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text -> IO (Either Text (RootedCleanupLease scope rootPlanId brokerGeneration catalogId frame sessionId verb))
acquireRootedCleanupLeaseKernel journal operation =
    acquireRootedCleanupLeaseChecked journal operation (\_ _ _ -> pure (Right ()))

acquireRootedCleanupLeaseChecked ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb -> Text ->
    (forall session. ProtectedSession session -> Text -> Text -> IO (Either Text ())) ->
    IO (Either Text (RootedCleanupLease scope rootPlanId brokerGeneration catalogId frame sessionId verb))
acquireRootedCleanupLeaseChecked journal operation check = mask $ \restore -> do
    acquired <- newEmptyMVar
    release <- newEmptyMVar
    finished <- newEmptyMVar
    worker <- forkFinally (withRootedOperationJournalKernel journal $ \store epoch session _fence permit pending ->
        case lookup operation pending of
            Nothing -> pure (Left "rooted cleanup lease: operation is not prepared")
            Just gate -> do
                entered <- withProtectedEntry store $ \protected -> do
                    live <- validateAllocatedBrokerEpochKernel protected epoch
                    case live of
                        Left failure -> pure (Right (Left (Text.pack (show failure))))
                        Right () -> do
                            valid <- validatePreparedGateForSettlementKernel protected session gate permit
                            case valid of
                                Left failure -> pure (Right (Left (Text.pack (sessionErrorMessage failure))))
                                Right () -> do
                                    checked <- check protected (preparedGatePlan gate) (preparedGateOperation gate)
                                    case checked of
                                        Left failure -> pure (Right (Left failure))
                                        Right () -> do
                                            putMVar acquired (Right ())
                                            takeMVar release
                                            pure (Right (Right ()))
                pure $ case entered of
                    Left failure -> Left (Text.pack (show failure))
                    Right (Left failure) -> Left failure
                    Right (Right ()) -> Right (permit, pending, ())) $ \outcome -> do
        let result = case outcome of
                Left exception -> Left (Text.pack (displayException (exception :: SomeException)))
                Right value -> value
        _ <- tryPutMVar acquired result
        putMVar finished result
    let unlock = do
            _ <- tryPutMVar release ()
            readMVar finished
    result <- restore (takeMVar acquired) `onException` (killThread worker >> unlock >> pure ())
    pure (case result of Left failure -> Left failure; Right () -> Right (RootedCleanupLease release finished))

-- | Retain the lease only if the exact predecessor is still present under it.
withRootedCleanupLeaseForPredecessorKernel ::
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text -> Maybe ByteString ->
    (RootedCleanupLease scope rootPlanId brokerGeneration catalogId frame sessionId verb -> IO (Either Text ())) ->
    IO (Either Text ())
withRootedCleanupLeaseForPredecessorKernel journal frameSession operation expected use =
    withRootedFrameSessionKernel frameSession $ \attached _ _ _ frame _ _ _ _ _ ->
        if not attached then pure (Left "rooted cleanup lease: predecessor requires an attached frame") else mask $ \restore -> do
            acquired <- restore $ acquireRootedCleanupLeaseChecked journal operation $ \protected plan resource -> do
                observed <- readRootedResourcePredecessorInEntryKernel protected frame plan resource
                pure $ do
                    actual <- observed
                    if actual == expected then Right () else Left "rooted cleanup lease: resource predecessor changed"
            case acquired of
                Left failure -> pure (Left failure)
                Right lease -> do
                    result <- restore (use lease) `onException` (releaseRootedCleanupLeaseKernel lease >> pure ())
                    case result of
                        Left failure -> releaseRootedCleanupLeaseKernel lease >> pure (Left failure)
                        Right () -> pure (Right ())

releaseRootedCleanupLeaseKernel ::
    RootedCleanupLease scope rootPlanId brokerGeneration catalogId frame sessionId verb -> IO (Either Text ())
releaseRootedCleanupLeaseKernel (RootedCleanupLease release finished) = do
    _ <- tryPutMVar release ()
    readMVar finished

{- | Open the catalog-selected child plan's real journal and observed fence.

The attached session chooses its own catalog and frame; no caller supplies a
plan digest, fence number, or session identifier. The root authority must be
the same project, store, verb, and broker generation as the live runtime. The
fixed-unit continuation receives the actual journal session, fence, and permit
at the catalog-selected plan index. The continuation owns settlement and closure;
a failed continuation leaves the session for the existing recovery protocol
instead of guessing that an effect did not run.
-}
withRootedFrameJournalKernel ::
    forall scope brokerGeneration verb rootPlanId catalogId frame sessionId.
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootInvocationAuthority scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    ProtectedStore ->
    ( forall childPlanId.
      OperationSession scope childPlanId ->
      FenceEpoch scope childPlanId ->
      ProjectPermit scope childPlanId ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
{-# OPAQUE withRootedFrameJournalKernel #-}
withRootedFrameJournalKernel runtime root session catalog store use =
    withRootedFrameSessionKernel session $ \attached verbName _lineage catalogIdentity frame _path token _stage _ordinal _predecessor ->
        withRecursiveHandoffRuntimeKernel runtime $ \atRoot project _tag runtimeStore generation runtimeVerb _keyDigest current ->
            case admit attached verbName catalogIdentity frame atRoot project runtimeStore generation runtimeVerb current of
                Left failure -> pure (Left failure)
                Right () -> case selected frame token of
                    [action] -> action
                    _ -> pure (Left (nodeFailure "the session does not select exactly one cataloged frame"))
  where
    admit attached verbName catalogIdentity frame atRoot project runtimeStore generation runtimeVerb current = do
        require "an unattached session cannot open a frame journal" attached
        require "a keyless nested arm cannot open a frame journal" atRoot
        require "the runtime is not path-agnostic" (isNothing current)
        require "the session names another catalog" (catalogIdentity == rootedPlanCatalogRecordIdentityKernel catalog)
        require "the catalog belongs to another root authority" $
            withRootedPlanCatalogRootKernel catalog $ \_ catalogRoot _ _ _ ->
                rootAuthorityStoreIdentity catalogRoot == rootAuthorityStoreIdentity root
                    && rootAuthorityProjectName catalogRoot == rootAuthorityProjectName root
                    && brokerEpochWord (rootAuthorityEpoch catalogRoot) == brokerEpochWord (rootAuthorityEpoch root)
                    && projectVerbName (rootAuthorityVerb catalogRoot) == projectVerbName (rootAuthorityVerb root)
        require "the session frame is empty" (not (Text.null frame))
        require "the runtime names another project" (project == rootAuthorityProjectName root)
        require "the runtime names another store" (runtimeStore == rootAuthorityStoreIdentity root)
        require "the supplied store differs from the root authority" (protectedStoreIdentityText (protectedStoreIdentity store) == rootAuthorityStoreIdentity root)
        require "the runtime names another broker generation" (generation == brokerEpochWord (rootAuthorityEpoch root) && generation > 0)
        require "the runtime or session names another verb" (runtimeVerb == projectVerbName (rootAuthorityVerb root) && verbName == runtimeVerb)

    selected frame token =
        [ action
        | Just action <-
            withRootedPlanCatalogEntriesKernel catalog $ \plan _binding currentFrame _parent (ChildFrameId child) _raw _route _payload _configDigest _payloadDigest _keys ->
                if child == frame && currentFrameId currentFrame == frame
                    then Just (open plan token)
                    else Nothing
        ]

    open :: forall specDigest childPlanId childConfigId cfg. ProjectPlan scope specDigest childPlanId childConfigId cfg -> Text -> IO (Either Text ())
    open plan token = do
        let digest = stablePlanSnapshotDigest (renderSnapshot plan)
        entered <- withProtectedEntry store $ \protected -> do
            live <- validateAllocatedBrokerEpochKernel protected (rootAuthorityEpoch root)
            case live of
                Left failure -> pure (Right (Left (Text.pack (show failure))))
                Right () -> do
                    opened <- openProjectJournal protected digest
                    case opened of
                        Left failure -> pure (Right (Left (Text.pack (sessionErrorMessage failure))))
                        Right (initial :: ProjectPermit scope childPlanId) -> do
                            fence <- establishInitialFence protected initial 1
                            case fence of
                                Left failure -> pure (Right (Left (Text.pack (sessionErrorMessage failure))))
                                Right observed -> do
                                    started <- openOperationSession protected (rootAuthorityEpoch root) digest (rootedOperationSessionName token (fenceEpochWord observed)) initial
                                    pure (Right (case started of
                                        Left failure -> Left (Text.pack (sessionErrorMessage failure))
                                        Right (operationSession, afterOpen) -> Right (operationSession, observed, afterOpen)))
        case entered of
            Left failure -> pure (Left (nodeFailure (Text.pack (show failure))))
            Right (Left failure) -> pure (Left (nodeFailure failure))
            Right (Right (operationSession, fence, permit)) -> use operationSession fence permit

-- | Mint a forward grant only from the retained journal's exact unknown gates.
withJournalPreparedRootedNodeGrantKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text -> Text -> [Text] -> [Text] -> [RootProbeIdentity] -> [RootedResourceObservation] -> Maybe (Maybe ByteString) ->
    (forall node. PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb -> IO (Either Text ())) ->
    IO (Either Text ())
-- The plan-derived prerequisites recheck against their rows in the entry that
-- publishes the node's Unknown records; a missing, stale or released one refuses
-- before any Unknown row, gate or grant exists.
withJournalPreparedRootedNodeGrantKernel runtime session journal localDigest node dependencies projections prerequisites observations predecessor use =
    withJournalPreparedRootedNodeGrantInternal runtime session journal localDigest node dependencies projections prerequisites observations predecessor Nothing use

-- | The caller establishes the effect coordinates before entering this private route.
withJournalPreparedRootedEffectNodeGrantKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text -> Text -> [Text] -> [Text] -> [RootProbeIdentity] -> [RootedResourceObservation] -> [(Text, Text, Text)] ->
    (forall node. PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb -> IO (Either Text ())) ->
    IO (Either Text ())
withJournalPreparedRootedEffectNodeGrantKernel runtime session journal localDigest node dependencies projections prerequisites observations effects use =
    withJournalPreparedRootedNodeGrantInternal runtime session journal localDigest node dependencies projections prerequisites observations Nothing (Just effects) use

withJournalPreparedRootedNodeGrantInternal ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    RootedOperationJournal scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    Text -> Text -> [Text] -> [Text] -> [RootProbeIdentity] -> [RootedResourceObservation] -> Maybe (Maybe ByteString) -> Maybe [(Text, Text, Text)] ->
    (forall node. PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb -> IO (Either Text ())) ->
    IO (Either Text ())
withJournalPreparedRootedNodeGrantInternal runtime session journal localDigest node dependencies projections prerequisites observations predecessor effects use =
    withRootedFrameSessionKernel session $ \attached _ _ catalog frame _ token _ _ _ ->
        withRecursiveHandoffRuntimeKernel runtime $ \atRoot _ _ runtimeStore generation _ _ current ->
            if not attached || not atRoot || not (isNothing current) || generation == 0 || Text.null node
                || any Text.null dependencies || node `elem` projections || any Text.null projections
                || length projections /= length (nub projections)
                || maybe False ((/= (node : projections)) . map (\(key, _, _) -> key)) effects
                then pure (Left (nodeFailure "invalid journal-backed node coordinates"))
                else do
                    admitted <- validateRootedJournalCoordinatesKernel journal runtimeStore generation localDigest token
                    case admitted of
                        Left failure -> pure (Left failure)
                        Right False -> pure (Left (nodeFailure "the journal names another plan, session, store, or generation"))
                        Right True -> do
                            result <- case effects of
                                Nothing -> prepareRootedOperationJournalForPrerequisitesKernel journal prerequisites observations (node : projections)
                                Just coordinates -> prepareRootedEffectJournalForPrerequisitesKernel journal prerequisites observations coordinates
                            case result of
                                Left failure -> pure (Left failure)
                                Right gates | map preparedGateOperation gates /= node : projections -> pure (Left (nodeFailure "the journal returned other operations"))
                                Right gates -> case traverse (packageRootedJournalGateKernel localDigest catalog frame token generation (isJust effects)) gates of
                                    Left failure -> pure (Left failure)
                                    Right (own : projected) -> case traverse (renderReversePreparedGateEnvelopeKernel own) predecessor of
                                        Left failure -> pure (Left failure)
                                        Right wrapped -> use (mintPreparedNodeGrantKernel node dependencies (maybe own id wrapped) (renderPreparedGatePackagesKernel projected))
                                    Right [] -> pure (Left (nodeFailure "the journal returned no node gate"))

{- | Settle one executor observation exactly once, or replay its exact result.

Everything the request echoes is checked against the session's own coordinates
before a byte is written: path, session token, nonce, ordinal, and the
predecessor digest the session recorded when it attached. Only @SettleNode@ and
@DescendResult@ settle; every other request form refuses through one fixed
continuation, so a post-open request of the wrong family cannot reach the
durable transition.

The supplied signed response must belong to the paired @Settled | Refused@
family and must echo the same path, session, nonce, and ordinal. The
observation row is published and strictly read back first, and only then is the
response's digest taken, so a response can never be recorded for an observation
that was not durably settled.

Settling twice is one settlement. The row is keyed by lineage, catalog, frame, session,
node, and ordinal and its bytes carry the observation, so an exact retry
converges on the record already present; a different observation under the same
coordinates comes back as different bytes and refuses without effect. No child
gate or local execution authority is created here.
-}
withSettledRootedNodeKernel ::
    RecursiveHandoffRuntime scope brokerGeneration verb ->
    RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb ->
    ProtectedStore ->
    Text ->
    ByteString ->
    ByteString ->
    (RecordKey -> ByteString -> IO (Either Text ())) ->
    (Text -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withSettledRootedNodeKernel #-}
withSettledRootedNodeKernel runtime session store node request signedSettled beforePublish use =
    withRootedFrameSessionKernel session $
        \attached _verb lineage catalogIdentity frame path token _stage ordinal predecessor ->
            withRecursiveHandoffRuntimeKernel runtime $
                \atRoot _project _tag _store generation _runtimeVerb _keyDigest current ->
                    case admit generation attached atRoot current frame path token ordinal predecessor of
                        Left failure -> pure (Left failure)
                        Right observation -> case rootedSettlementSessionTokenKernel session of
                            Nothing -> pure (Left (nodeFailure "the frame has no attached settlement identity"))
                            Just scopedToken -> case (rootedSettlementKeyKernel lineage catalogIdentity frame token node ordinal, rootedSettlementKeyKernel lineage catalogIdentity frame scopedToken node ordinal) of
                                (Right legacyKey, Right scopedKey) -> do
                                    let row name = renderSettledRow lineage catalogIdentity frame name node ordinal observation
                                    selected <- selectRootedSettlementAddressKernel store legacyKey (row token) scopedKey (row scopedToken)
                                    case selected of
                                        Left failure -> pure (Left (nodeFailure failure))
                                        Right (key, settled) -> do
                                            existing <- checkRootedSettlementRowKernel store key settled (beforePublish key settled)
                                            case existing of
                                                Left failure -> pure (Left (nodeFailure failure))
                                                Right () -> do
                                                    published <- publishRootedSettlementExactKernel store key settled
                                                    case published of
                                                        Left failure -> pure (Left failure)
                                                        Right _ -> use (childConfigDigest signedSettled)
                                (Left failure, _) -> pure (Left (nodeFailure (Text.pack (sessionErrorMessage failure))))
                                (_, Left failure) -> pure (Left (nodeFailure (Text.pack (sessionErrorMessage failure))))
  where
    admit generation attached atRoot current frame path token ordinal predecessor = do
        require "the broker generation is zero" (generation > 0)
        require "the requester path does not end at the session frame" (not (null path) && last path == frame)
        require "an unattached rooted frame session cannot settle a node" attached
        require "a keyless nested arm cannot settle a node" atRoot
        require "the runtime is not path-agnostic" (isNothing current)
        require "the settled node key is empty" (not (Text.null node))
        require "the session has no recorded predecessor" (isJust predecessor)
        decoded <- either (Left . nodeFailure) Right (rootedLifecycleRequestFromWireKernel request)
        (requestPath, requestSession, requestOrdinal, requestNonce, requestPredecessor, body) <-
            withRootedLifecycleRequestKernel
                decoded
                (const outsideSettlement)
                (\_ _ _ _ _ _ -> outsideSettlement)
                (\p s _ o n pre b -> Right (p, s, o, n, pre, b))
                (\p s _ o n pre b -> Right (p, s, o, n, pre, b))
                (\_ _ _ _ _ _ -> outsideSettlement)
                (\_ _ _ _ _ _ -> outsideSettlement)
        require "the settle request echoes another requester path" (requestPath == path)
        require "the settle request echoes another session" (requestSession == token)
        require "the settle request echoes another ordinal" (requestOrdinal == ordinal)
        require "the settle request nonce is empty" (not (ByteString.null requestNonce))
        require "the settle request echoes another predecessor" (Just requestPredecessor == predecessor)
        require "the settled observation is empty" (not (ByteString.null body))
        response <-
            either (Left . nodeFailure) Right (rootedLifecycleResponseFromWireKernel signedSettled)
        (responseDigest, responsePath, responseSession, responseOrdinal, responseNonce, responseBody) <-
            withRootedLifecycleResponseKernel
                response
                (\_ _ _ _ _ _ -> outsideSettlementFamily)
                (\_ _ _ _ _ _ _ _ _ _ _ -> outsideSettlementFamily)
                (\_ _ _ _ _ _ _ _ -> outsideSettlementFamily)
                (\digest p s _ o n responseBody _ -> Right (digest, p, s, o, n, responseBody))
                (\_ _ _ _ _ _ _ _ -> outsideSettlementFamily)
                (\_ _ _ _ _ _ _ _ -> outsideSettlementFamily)
                (\_ _ _ _ _ _ _ _ -> Left (nodeFailure "a signed Refused response does not settle a rooted node"))
        require "the signed response echoes another request" (responseDigest == childConfigDigest request)
        require "the signed response echoes another observation" (responseBody == TextEncoding.encodeUtf8 (childConfigDigest body))
        require "the signed response echoes another requester path" (responsePath == path)
        require "the signed response echoes another session" (responseSession == token)
        require "the signed response does not select a successor ordinal" (responseOrdinal > ordinal)
        require "the signed response echoes another nonce" (responseNonce == requestNonce)
        pure body

    outsideSettlement =
        Left (nodeFailure "only a SettleNode or DescendResult request settles a rooted node")
    outsideSettlementFamily =
        Left (nodeFailure "only a paired Settled response settles a rooted node")

    renderSettledRow lineage catalogIdentity frame token settledNode ordinal observation =
        ByteString.concat
            [ framedText rootedSettlementDomain
            , framedWord 1
            , framedText "settled"
            , framedText lineage
            , framedText catalogIdentity
            , framedText frame
            , framedText token
            , framedText settledNode
            , framedWord ordinal
            , frameWire observation
            ]

rootedSettlementDomain :: Text
rootedSettlementDomain = "hostbootstrap/rooted-node-settlement"

framedText :: Text -> ByteString
framedText = frameWire . TextEncoding.encodeUtf8

framedWord :: Word64 -> ByteString
framedWord = frameWire . LazyByteString.toStrict . Builder.toLazyByteString . Builder.word64BE

require :: Text -> Bool -> Either Text ()
require _ True = Right ()
require detail False = Left (nodeFailure detail)

nodeFailure :: Text -> Text
nodeFailure detail = "rooted node: " <> detail

rootedOperationSessionName :: Text -> Word64 -> Text
rootedOperationSessionName token fence = token <> "-f" <> Text.pack (show fence)
