{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Package-private durable preparation of one exact reverse descent.

The public teardown forest owns the work and settlement constructors. This
module binds one constructor-hidden work package to its exact root lifecycle
entry and records the canonical recovery adapter before an edge exists.
-}
module HostBootstrap.Teardown.Internal (
    ReverseDescent,
    withReverseDescentLiftContextKernel,
    withReverseDescentProcessInputsKernel,
    withPreparedReverseForestKernel,
    withPreparedReverseAdmissionsKernel,
    renderPreparedReverseTerminalOriginKernel,
    withPreparedReverseDescentKernel,
    withBoundReverseDescentKernel,
    withRehydratedBoundReverseDescentKernel,
    withRehydratedSettledReverseDescentKernel,
    withVerifiedBoundReverseDescentReportKernel,
    withVerifiedBoundReverseDescentObservationsKernel,
    decideReverseRequestKernel,
    classifyRehydratedBoundRecordKernel,
    rebindAdoptedReverseDescentKernel,
    classifyPrepared,
    parseBoundRecord,
    verifyChildObservations,
)
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority
import HostBootstrap.Authority.Kernel (rootAuthorityStoreIdentity)
import HostBootstrap.Handoff
import qualified HostBootstrap.Handoff.Rooted as RootedWire
import HostBootstrap.Handoff.Internal (
    RecoverySigningKernel,
    consumeRecoverySigningKernel,
    recoverySigningKernel,
 )
import HostBootstrap.Handoff.Recovery (
    recoveryChildPackageFromWireKernel,
    recoveryChildPackageKernel,
    renderRecoveryChildPackageKernel,
    withRecoveryChildPackageKernel,
 )
import HostBootstrap.Lifecycle.Context (ValidatedLifecycleContext)
import HostBootstrap.Lifecycle.Context.Internal (withValidatedRootLifecycleContext)
import HostBootstrap.Lifecycle.Mode
import qualified HostBootstrap.Lifecycle.Plan as Plan
import HostBootstrap.Lifecycle.RootedPlan (
    RootedPlanCatalog,
    withRootedPlanCatalogEdgeKernel,
    ParentFrameId (ParentFrameId),
    ChildFrameId (ChildFrameId),
    ConfigDigest (ConfigDigest),
 )
import HostBootstrap.Lift.Context (LiftContext, liftContextFromLayers, liftLayers)
import HostBootstrap.ProjectPlan
import HostBootstrap.ProjectPlan.Frame
import HostBootstrap.Protected
import HostBootstrap.Teardown
import HostBootstrap.Teardown.Preparation (PreparationFacts (..), classifyPreparedRecord, renderReverseAdapterKernel, validatePreparation, validateRecoveryOfferScope)

{- | Decide one reverse-service request against retained state without a store
or broker effect. The left input is a rendered offer binding; the right input is
an already decoded rooted request. Only settlement returns a forest successor.
-}
decideReverseRequestKernel ::
    Text ->
    TeardownForest scope planId frame verb ->
    Maybe Text ->
    Maybe ByteString ->
    Maybe ByteString ->
    Bool ->
    Either ByteString RootedWire.RootedLifecycleRequest ->
    Either Text (Maybe (Text, TeardownOutcome, [RootedWire.RootedReverseResource], TeardownForest scope planId frame verb))
decideReverseRequestKernel frame forest prepared pending offered terminal input = case input of
    Left binding -> case offered of
        Nothing -> Right Nothing
        Just existing
            | existing == binding -> Right Nothing
            | otherwise -> Left "the reverse frame already retains another handoff offer"
    Right request ->
        RootedWire.withRootedLifecycleRequestKernel request
            (const (Right Nothing))
            (\_ _ _ _ _ _ -> checkNext)
            (\_ _ _ _ _ _ body -> Just <$> settle body)
            (\_ _ _ _ _ _ body -> case pending of
                Nothing -> Left "no completed descent awaits this result"
                Just expected
                    | expected == body -> Right Nothing
                    | otherwise -> Left "the descent result differs from the completed child")
            (\_ _ _ _ _ _ -> checkClose)
            (\_ _ _ _ _ _ -> if terminal then Right Nothing else Left "no FrameComplete has been issued for this session")
  where
    checkNext =
        eliminateTeardownProgress
            (nextTeardownWork forest)
            (const (Left "the frame is complete; CloseFrame is required"))
            ( \point -> withTeardownAuthorization point
                (const (Right Nothing))
                (\_ work -> eliminateTeardownWork work
                    (\local -> maybe (Right Nothing) Left (lookup (localWorkKey local) (teardownForestFailures forest)))
                    (const (Right Nothing)))
            )
    checkClose =
        eliminateTeardownProgress
            (nextTeardownWork forest)
            (const (case offered of Nothing -> Left "the frame requested completion before its admitted offer was retained"; Just _ -> Right Nothing))
            (const (Left "the frame requested completion before its exact work settled"))
    settle observation = do
        result@(node, _, _, _) <- advanceReverseLocalKernel frame forest observation
        case prepared of
            Nothing -> Left "the frame has no prepared node for this settlement"
            Just expected | expected /= node -> Left "the settlement names another prepared node"
            _ -> Right result

advanceReverseLocalKernel ::
    Text ->
    TeardownForest scope planId frame verb ->
    ByteString ->
    Either Text (Text, TeardownOutcome, [RootedWire.RootedReverseResource], TeardownForest scope planId frame verb)
advanceReverseLocalKernel frame forest observation =
    eliminateTeardownProgress
        (nextTeardownWork forest)
        (const (Left "the frame is already complete"))
        ( \point ->
            withTeardownAuthorization
                point
                (const (Left "a child cannot settle root-owned pre-descent work"))
                ( \_ work ->
                    eliminateTeardownWork
                        work
                        ( \local -> do
                            let node = localWorkKey local
                            RootedWire.RootedReverseObservation _ body resources <-
                                RootedWire.readRootedReverseObservationForPlanKernel frame node [node] observation
                            rows <- either (Left . Text.pack . teardownErrorMessage) Right (teardownObservationsFromWire body)
                            case rows of
                                [(actual, outcome)] | actual == node -> Right (node, outcome, resources, attemptLocalWork local outcome)
                                _ -> Left "a local settlement must carry exactly its prepared observation"
                        )
                        (const (Left "a local settlement cannot advance descent work"))
                )
        )

{- | One parent-local reverse descent through its durable lifecycle states.

Prepared retains the sealed root entry, original forest continuation,
canonical adapter, verifier, and durable readback. Bound nests that exact
package with canonical binding bytes and its exact successor record; the
live offer remains lexical to the relay callback that attached it.
-}
data
    ReverseDescent
        state
        scope
        planId
        parentFrame
        childFrame
        brokerGeneration
        verb
        descentId
    where
    PreparedReverseDescent ::
        RootInvocationAuthority scope brokerGeneration verb ->
        ProjectVerb verb ->
        ProjectPlan scope specDigest planId configId cfg ->
        ValidatedLifecycleContext scope specDigest planId configId rootFrame ->
        AcquisitionJournal scope planId brokerGeneration ->
        LifecycleCursor scope planId rootFrame brokerGeneration verb phase ->
        CommandAuthority scope planId rootFrame brokerGeneration verb phase ->
        IO (Either AuthorityError (CommandAuthority scope planId rootFrame brokerGeneration verb phase)) ->
        DescentWork scope planId parentFrame childFrame verb ->
        HandoffBindingInput ->
        ByteString ->
        Text ->
        [Text] ->
        ( [(Text, TeardownOutcome)] ->
          Either TeardownError (SubtreeSettled scope planId childFrame verb)
        ) ->
        ProtectedStore ->
        RecordKey ->
        RecordVersion ->
        ByteString ->
        ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId
    BoundReverseDescent ::
        ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
        ByteString ->
        RecordVersion ->
        ByteString ->
        ReverseDescent
            (HandoffOffer scope brokerGeneration)
            scope
            planId
            parentFrame
            childFrame
            brokerGeneration
            verb
            descentId

type role ReverseDescent nominal nominal nominal nominal nominal nominal nominal nominal

-- | Derive the exact plan-owned launch context retained by one reverse edge.
withReverseDescentLiftContextKernel ::
    ReverseDescent state scope planId parentFrame childFrame brokerGeneration verb descentId ->
    (LiftContext -> IO (Either Text ())) ->
    IO (Either Text ())
{-# OPAQUE withReverseDescentLiftContextKernel #-}
withReverseDescentLiftContextKernel reverseDescent use = case reverseDescent of
    BoundReverseDescent prepared _ _ _ ->
        withReverseDescentLiftContextKernel prepared use
    PreparedReverseDescent _ verb plan _ _ _ _ _ descent _ _ _ _ _ _ _ _ _ ->
        let parent = descentWorkParentFrame descent
            expectedChild = descentWorkChildFrame descent
         in withDescentWorkSubtree descent $ \subtree ->
                case topologyDescentFrom (topology plan) parent of
                    Nothing -> pure (Left "the retained descent parent has no plan-owned lift context")
                    Just (child, _immediateContext)
                        | child /= expectedChild ->
                            pure (Left "the plan-owned lift context enters a different child")
                        | teardownPlanFrameId subtree /= expectedChild ->
                            pure (Left "the retained descent subtree opens at a different child")
                        | teardownPlanVerbName subtree /= projectVerbName verb ->
                            pure (Left "the retained descent subtree has a different reverse verb")
                        | otherwise ->
                            case rootedRouteTo (topology plan) expectedChild of
                                Left failure -> pure (Left failure)
                                Right context -> context `seq` use context
  where
    rootedRouteTo derived target = do
        layers <- collect target []
        case liftContextFromLayers layers of
            Left failure -> Left ("the retained topology route is invalid: " <> Text.pack failure)
            Right context -> Right context
      where
        root = fst (NonEmpty.head (topologyFrameOrder derived))
        collect current visited
            | current == root = Right []
            | current `elem` visited = Left "the retained topology route contains a cycle"
            | otherwise = case topologyParentFrame derived current of
                Nothing -> Left "the retained descent child is not reachable from the root frame"
                Just parent -> case [ liftLayers context
                                    | (edgeParent, edgeChild, context) <- topologyDescentEdges derived
                                    , edgeParent == parent
                                    , edgeChild == current
                                    ] of
                    [layers] -> (<> layers) <$> collect parent (current : visited)
                    [] -> Left "the retained topology route has no lift for one parent edge"
                    _ -> Left "the retained topology route duplicates one parent edge"

{- | Recover the exact opaque package and route inputs retained by preparation.
Canonical decoding happens inside the owning module; callers receive neither
raw package bytes nor a constructor.
-}
withReverseDescentProcessInputsKernel ::
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    (RecoveryChildPackage -> LiftContext -> HandoffBindingInput -> ProjectVerb verb -> IO (Either Text ())) ->
    IO (Either Text ())
withReverseDescentProcessInputsKernel descent use =
    withReverseDescentLiftContextKernel descent $ \route -> case descent of
        PreparedReverseDescent _ verb _ _ _ _ _ _ _ input package _ _ _ _ _ _ _ ->
            case recoveryChildPackageFromWireKernel package of
                Left failure -> pure (Left failure)
                Right recovered -> use recovered route input verb

{- | Open the exact child projection retained by prepared descent.

The projection and forest remain continuation-bound to the hidden descent
index, so a rooted service can schedule this child without reconstructing its
plan position from descriptive frame text.
-}
withPreparedReverseForestKernel ::
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    ( TeardownPlan scope planId childFrame verb ->
      TeardownForest scope planId childFrame verb ->
      result
    ) ->
    Either TeardownError result
withPreparedReverseForestKernel
    (PreparedReverseDescent _ _ _ _ _ _ _ _ descent _ _ _ _ _ _ _ _ _)
    use =
        withDescentWorkSubtree descent $ \projection -> do
            forest <- openTeardownForest projection
            pure (use projection forest)

{- | Lend the exact edge and recovery admissions retained by preparation.

The callbacks compare canonical binding input and the independently signed
recovery coordinates before returning the package's canonical adapter. They
remain lexical to the prepared value and expose neither package bytes nor a
constructor.
-}
withPreparedReverseAdmissionsKernel ::
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    ( (HandoffBindingInput -> IO (Either Text ())) ->
      ( forall planDigest recoveryParent recoveryChild.
        RecoveryProjectionBindingInput planDigest recoveryParent recoveryChild ->
        IO (Either Text ByteString)
      ) ->
      result
    ) ->
    result
withPreparedReverseAdmissionsKernel
    (PreparedReverseDescent _ _ _plan _ _ _ _ _ descent expectedInput package _ _ _ _ _ _ _)
    use =
        use admitEdge admitRecovery
      where
        parent = descentWorkParentFrame descent
        child = descentWorkChildFrame descent
        digest = requestedPlanRevision expectedInput

        admitEdge observed =
            pure $
                if renderHandoffBindingInput observed == renderHandoffBindingInput expectedInput
                    then Right ()
                    else Left "the requested reverse edge differs from its prepared binding input"

        admitRecovery ::
            forall planDigest recoveryParent recoveryChild.
            RecoveryProjectionBindingInput planDigest recoveryParent recoveryChild ->
            IO (Either Text ByteString)
        admitRecovery observed
            | requestedRecoveryPlanDigest observed /= digest = refused "the recovery plan digest differs"
            | requestedRecoveryParentFrame observed /= parent = refused "the recovery parent frame differs"
            | requestedRecoveryChildFrame observed /= child = refused "the recovery child frame differs"
            | otherwise =
                pure $ do
                    recovered <- recoveryChildPackageFromWireKernel package
                    Right (withRecoveryChildPackageKernel recovered (\_ adapter -> adapter))

        refused = pure . Left

{- | Render the reverse terminal origin predicted by one prepared descent and
the exact binding the root retained for its Offer. This is the root-side twin
of the recovery child's sealed origin renderer.
-}
renderPreparedReverseTerminalOriginKernel ::
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    ByteString ->
    Either Text ByteString
renderPreparedReverseTerminalOriginKernel
    (PreparedReverseDescent _ verb _plan _ journal cursor authority _ descent input _ packageDigest _ _ _ _ _ _)
    binding = do
        require "the retained binding is empty" (not (ByteString.null binding))
        require "the binding child differs" (requestedChildFrame input == descentWorkChildFrame descent)
        let digest = requestedPlanRevision input
            frame = descentWorkChildFrame descent
            closed = projectVerbName verb
        pure . ByteString.concat . map frameWire $
            [ "child-recovery-terminal-origin-v1"
            , "1"
            , binding
            , TextEncoding.encodeUtf8 digest
            , TextEncoding.encodeUtf8 digest
            , TextEncoding.encodeUtf8 (invocationIdText (commandAuthorityInvocation authority))
            , word (acquisitionJournalRecordVersion journal)
            , word (lifecycleCursorRecordVersion cursor)
            , TextEncoding.encodeUtf8 frame
            , word (brokerEpochWord (commandAuthorityEpoch authority))
            , TextEncoding.encodeUtf8 closed
            , TextEncoding.encodeUtf8 (projectVerbName (commandAuthorityVerb authority))
            , TextEncoding.encodeUtf8 (lifecyclePhaseName (commandAuthorityPhase authority))
            , TextEncoding.encodeUtf8 frame
            , TextEncoding.encodeUtf8 closed
            , TextEncoding.encodeUtf8 packageDigest
            ]
      where
        word = ByteStringChar8.pack . show
        require failure accepted
            | accepted = Right ()
            | otherwise = Left failure

{- | Prepare one exact root-entry descent, or return its unchanged work.

The hidden admission is scrutinized before any retained term. Exact command
reauthorization precedes the prepared-record entry; the cursor is revalidated
again inside that entry, and the continuation runs only after it unlocks.

The canonical child configuration is never supplied by a caller: it comes only
from the recursive catalog's own admitted entry for exactly this parent and
child frame, and the recovery adapter comes only from this plan's own reverse
projection. the authenticated-handoff phase's neutral constructor
(DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md) then joins the two into the
complete 'HostBootstrap.Handoff.Recovery.RecoveryChildPackage', whose canonical
bytes — never the adapter alone — become the prepared payload, the durable
record's payload frame, and the offer the root signs.
-}
withPreparedReverseDescentKernel ::
    Plan.AcquisitionJournalAdmission ->
    RootInvocationAuthority scope brokerGeneration verb ->
    ProjectVerb verb ->
    ProjectPlan scope specDigest planId configId cfg ->
    RootedPlanCatalog scope planId brokerGeneration catalogId ->
    ValidatedLifecycleContext scope specDigest planId configId rootFrame ->
    AcquisitionJournal scope planId brokerGeneration ->
    LifecycleCursor scope planId rootFrame brokerGeneration verb phase ->
    CommandAuthority scope planId rootFrame brokerGeneration verb phase ->
    IO (Either AuthorityError (CommandAuthority scope planId rootFrame brokerGeneration verb phase)) ->
    DescentWork scope planId parentFrame childFrame verb ->
    ( forall descentId.
      ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
      IO result
    ) ->
    IO (Either (TeardownError, DescentWork scope planId parentFrame childFrame verb) result)
{-# OPAQUE withPreparedReverseDescentKernel #-}
withPreparedReverseDescentKernel admission =
    case Plan.consumeAcquisitionJournalAdmissionKernel admission of
        () -> prepareEntry
  where
    prepareEntry root verb plan catalog lifecycleContext journal cursor retained reauthorize descent use =
        case withValidatedRootLifecycleContext
            lifecycleContext
            (\_ store current frame _ -> prepare store current frame) of
            Left _ -> refused descent "the lifecycle context is not the exact root"
            Right action -> action
      where
        prepare store current frame =
            withDescentWorkSubtree descent $ \childProjection ->
                case openTeardownForest childProjection of
                    Left failure -> pure (Left (failure, descent))
                    Right childForest ->
                        let expected = teardownForestOutstanding childForest
                            snapshot = renderSnapshot plan
                            specDigest = stablePlanSnapshotSpecDigest snapshot
                            parent = descentWorkParentFrame descent
                            child = descentWorkChildFrame descent
                            invocation = invocationIdText (commandAuthorityInvocation retained)
                         in case catalogPackage parent child expected of
                                Left detail -> pure (Left (refusal detail, descent))
                                Right (childPlanDigest, adapter, childConfig, configDigest, package) ->
                                    let packageDigest = childConfigDigest package
                                        input =
                                            HandoffBindingInput
                                                { requestedSpecDigest = specDigest
                                                , requestedPayloadKind = RecoveryAdapterWire
                                                , requestedPlanRevision = childPlanDigest
                                                , requestedParentFrame = parent
                                                , requestedChildFrame = child
                                                , requestedChildConfigDigest = packageDigest
                                                , requestedPhase = "teardown"
                                                }
                                        bytes = renderPrepared root journal cursor snapshot invocation input packageDigest configDigest package
                                     in admitPrepared
                                            store
                                            current
                                            frame
                                            childProjection
                                            snapshot
                                            parent
                                            child
                                            expected
                                            adapter
                                            childConfig
                                            configDigest
                                            package
                                            packageDigest
                                            invocation
                                            input
                                            bytes

        catalogPackage parent child expected = do
            (childPlanDigest, childConfig, configDigest) <-
                withRootedPlanCatalogEdgeKernel catalog (ParentFrameId parent) (ChildFrameId child) selectChildConfig
            let adapter = renderReverseAdapterKernel childPlanDigest (projectVerbName verb) parent child expected
            package <- recoveryChildPackageKernel childConfig adapter
            pure (childPlanDigest, adapter, childConfig, configDigest, renderRecoveryChildPackageKernel package)

        selectChildConfig _parentCurrent _plan binding _current _raw _route payload (ConfigDigest configDigest) _payloadDigest _keys =
            (Plan.planDigestBindingDigestKernel binding, payload, configDigest)

        admitPrepared store current frame childProjection snapshot parent child expected adapter childConfig configDigest package packageDigest invocation input bytes =
            case validate store current frame childProjection snapshot parent child expected adapter childConfig configDigest package bytes of
                Left failure -> pure (Left (failure, descent))
                Right () -> case keyFor invocation (recoveryWireDigest package) of
                    Left failure -> pure (Left (failure, descent))
                    Right key -> do
                        replayed <- reauthorize
                        case replayed of
                            Left _ -> refused descent "the exact command reservation is stale"
                            Right authority
                                | not (sameCommandAuthority store retained authority) ->
                                    refused descent "the replayed command authority differs"
                                | otherwise -> do
                                    admitted <- withProtectedEntry store $ \session -> do
                                        currentCursor <- validateCurrentLifecycleCursor session cursor
                                        case currentCursor of
                                            Left _ ->
                                                pure
                                                    ( Right
                                                        (Left (refusal "the lifecycle cursor is stale"))
                                                    )
                                            Right () -> admit session key bytes >>= forceProtectedResult
                                    case admitted of
                                        Left _ -> refused descent "the prepared store entry failed"
                                        Right (Left failure) -> pure (Left (failure, descent))
                                        Right (Right version) ->
                                            Right
                                                <$> use
                                                    ( PreparedReverseDescent
                                                        root
                                                        verb
                                                        plan
                                                        lifecycleContext
                                                        journal
                                                        cursor
                                                        retained
                                                        reauthorize
                                                        descent
                                                        input
                                                        package
                                                        packageDigest
                                                        expected
                                                        (verifyChildObservations childProjection)
                                                        store
                                                        key
                                                        version
                                                        bytes
                                                    )

        validate store current frame childProjection snapshot parent child expected adapter childConfig configDigest package preparedBytes =
            either (Left . refusal) Right $
                validatePreparation
                    PreparationFacts
                        { preparationVerb = verbName
                        , preparationRootVerb = projectVerbName (rootAuthorityVerb root)
                        , preparationJournalVerb = acquisitionJournalRootVerb journal
                        , preparationCursorVerb = projectVerbName (lifecycleCursorVerb cursor)
                        , preparationCommandVerb = projectVerbName (commandAuthorityVerb retained)
                        , preparationCursorPhase = lifecyclePhaseName (lifecycleCursorPhase cursor)
                        , preparationCommandPhase = lifecyclePhaseName (commandAuthorityPhase retained)
                        , preparationProject = projectPlanProjectName plan
                        , preparationRootProject = rootAuthorityProjectName root
                        , preparationStore = storeIdentity
                        , preparationRootStore = rootAuthorityStoreIdentity root
                        , preparationPlanStore = Plan.projectPlanProfileStoreIdentityKernel plan
                        , preparationPlanScope = Plan.projectPlanProfileNameKernel plan
                        , preparationJournalScope = acquisitionJournalStableScope journal
                        , preparationPlanDigest = stablePlanSnapshotDigest snapshot
                        , preparationJournalDigest = acquisitionJournalSnapshotDigest journal
                        , preparationCanonicalPlan = stablePlanSnapshotBytes snapshot
                        , preparationRootEpoch = brokerEpochWord (rootAuthorityEpoch root)
                        , preparationJournalEpoch = acquisitionJournalBrokerGeneration journal
                        , preparationPlanEpoch = Plan.projectPlanProfileEpochKernel plan
                        , preparationCommandEpoch = brokerEpochWord (commandAuthorityEpoch retained)
                        , preparationCurrentFrame = currentFrameId current
                        , preparationProjectFrame = projectFrameId frame
                        , preparationCursorFrame = lifecycleCursorFrame cursor
                        , preparationCommandFrame = commandAuthorityFrame retained
                        , preparationChildProjectionFrame = teardownPlanFrameId childProjection
                        , preparationChildProjectionVerb = teardownPlanVerbName childProjection
                        , preparationParent = parent
                        , preparationChild = child
                        , preparationTopologyFrames = map fst (NonEmpty.toList (topologyFrameOrder (topology plan)))
                        , preparationTopologyEdges = topologyParentEdges (topology plan)
                        , preparationCursorMatchesCommand = lifecycleCursorMatchesCommandAuthority retained cursor
                        , preparationCommandMatchesStore = commandAuthorityMatchesStore retained store
                        , preparationRun = acquisitionJournalRunLease journal
                        , preparationInvocation = invocationIdText (commandAuthorityInvocation retained)
                        , preparationAcquisitionVersion = acquisitionJournalRecordVersion journal
                        , preparationCursorVersion = lifecycleCursorRecordVersion cursor
                        , preparationObservations = expected
                        , preparationAdapter = adapter
                        , preparationChildConfig = childConfig
                        , preparationConfigDigest = configDigest
                        , preparationActualConfigDigest = childConfigDigest childConfig
                        , preparationPackage = package
                        , preparationRenderedPackage = either (const ByteString.empty) renderRecoveryChildPackageKernel (recoveryChildPackageKernel childConfig adapter)
                        , preparationPackageDigest = childConfigDigest package
                        , preparationRecord = preparedBytes
                        , preparationWireBound = maxWireBytes
                        }
          where
            storeIdentity = protectedStoreIdentityText (protectedStoreIdentity store)
            verbName = projectVerbName verb

        keyFor invocation adapterDigest =
            case mkRecordKey
                ( "reverse-descent."
                    <> recoveryWireDigest (TextEncoding.encodeUtf8 invocation)
                    <> "."
                    <> adapterDigest
                ) of
                Left _ -> Left (refusal "the prepared record key is invalid")
                Right key -> Right key

        admit session key expected = do
            observed <- readProtectedRecord session key
            case observed of
                Left _ -> pure (Left (refusal "the prepared record could not be read"))
                Right (Just record) -> pure (classifyPrepared expected record)
                Right Nothing -> do
                    written <- compareAndSwapProtectedRecord session key ExpectAbsent expected
                    case written of
                        Left _ -> reread
                        Right version
                            | recordVersionWord version /= 1 -> pure conflict
                            | otherwise -> reread
                  where
                    reread = do
                        readback <- readProtectedRecord session key
                        pure $ case readback of
                            Right (Just record) -> classifyPrepared expected record
                            _ -> Left (refusal "the prepared record readback differs")
                    conflict = Left (refusal "a conflicting prepared record exists")

        renderPrepared rootEvidence journalEvidence cursorEvidence snapshot invocation input packageDigest configDigest package =
            ByteString.concat
                [ framedText "hostbootstrap/reverse-descent"
                , framedWord 1
                , framedText "prepared"
                , framedText (acquisitionJournalStableScope journalEvidence)
                , framedText (rootAuthorityProjectName rootEvidence)
                , framedText (rootAuthorityStoreIdentity rootEvidence)
                , framedWord (brokerEpochWord (rootAuthorityEpoch rootEvidence))
                , framedText invocation
                , framedText (acquisitionJournalRunLease journalEvidence)
                , framedWord (acquisitionJournalRecordVersion journalEvidence)
                , framedWord (lifecycleCursorRecordVersion cursorEvidence)
                , framedText (stablePlanSnapshotSpecDigest snapshot)
                , framedText (stablePlanSnapshotConfigDigest snapshot)
                , framedText (stablePlanSnapshotDigest snapshot)
                , framedText (projectVerbName (rootAuthorityVerb rootEvidence))
                , framedText "teardown"
                , frameWire (renderHandoffBindingInput input)
                , framedText packageDigest
                , framedText configDigest
                , frameWire package
                ]

        refusal = TeardownReverseDescentRefused
        refused work detail = pure (Left (refusal detail, work))

{- | Bind one prepared descent to the exact recoverably opened offer.

The hidden signing capability is forced before the prepared package or opener.
The exact command and current Prepared-or-Bound row are revalidated read-only
before opening; the cursor and row are checked again for the Bound CAS.
-}
withBoundReverseDescentKernel ::
    RecoverySigningKernel ->
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    (HandoffBindingInput -> ByteString -> IO (Either failure (HandoffOffer scope brokerGeneration))) ->
    ( ReverseDescent
        (HandoffOffer scope brokerGeneration)
        scope
        planId
        parentFrame
        childFrame
        brokerGeneration
        verb
        descentId ->
      HandoffOffer scope brokerGeneration ->
      IO (Either failure ())
    ) ->
    IO
        ( Either
            (TeardownError, ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId)
            (Either failure ())
        )
{-# OPAQUE withBoundReverseDescentKernel #-}
withBoundReverseDescentKernel kernel =
    kernel `seq`
        consumeRecoverySigningKernel
            kernel
            ( \prepared open use -> case prepared of
                PreparedReverseDescent root verb plan _ journal cursor retained reauthorize _ input package _ _ _ store key preparedVersion preparedBytes -> do
                    replayed <- reauthorize
                    case replayed of
                        Left _ -> refused prepared "the exact command reservation is stale"
                        Right authority
                            | not (sameCommandAuthority store retained authority) ->
                                refused prepared "the replayed command authority differs"
                            | otherwise -> do
                                checked <- withProtectedEntry store $ \session -> do
                                    current <- validateCurrentLifecycleCursor session cursor
                                    case current of
                                        Left _ -> pure (Right (Left (refusal "the lifecycle cursor is stale")))
                                        Right () -> precheckRecord session key preparedVersion preparedBytes >>= forceProtectedResult
                                case checked of
                                    Left _ -> refused prepared "the prepared store entry failed"
                                    Right (Left failure) -> pure (Left (failure, prepared))
                                    Right (Right ()) -> do
                                        opened <- open input package
                                        case opened of
                                            Left failure -> pure (Right (Left failure))
                                            Right offer -> case validateOffer root verb plan journal input package preparedBytes offer of
                                                Left failure -> pure (Left (failure, prepared))
                                                Right boundBytes -> do
                                                    entered <- withProtectedEntry store $ \session -> do
                                                        current <- validateCurrentLifecycleCursor session cursor
                                                        case current of
                                                            Left _ -> pure (Right (Left (refusal "the lifecycle cursor is stale")))
                                                            Right () -> bindRecord session key preparedVersion preparedBytes boundBytes >>= forceProtectedResult
                                                    case entered of
                                                        Left _ -> refused prepared "the bound store entry failed"
                                                        Right (Left failure) -> pure (Left (failure, prepared))
                                                        Right (Right version) ->
                                                            let bindingBytes = renderHandoffBinding (handoffOfferBinding offer)
                                                             in Right <$> use (BoundReverseDescent prepared bindingBytes version boundBytes) offer
            )
  where
    validateOffer root verb plan journal input package preparedBytes offer = do
        require "the recovery offer payload differs" (payload == package)
        require "the recovery offer token is empty" (not (ByteString.null token))
        require "the recovery offer binding is not canonical" (bindingBytes == renderHandoffBinding binding)
        require "the recovery offer project differs" (handoffInstalledProject binding == rootAuthorityProjectName root)
        either (Left . refusal) Right $
            validateRecoveryOfferScope productionScopeTag harnessScopeTagFor
                (acquisitionJournalStableScope journal) (handoffScope binding)
        require "the recovery offer store differs" (handoffStoreIdentity binding == rootAuthorityStoreIdentity root)
        require "the recovery offer broker differs" (handoffBrokerGeneration binding == brokerEpochWord (rootAuthorityEpoch root))
        require "the recovery offer verb differs" (handoffVerb binding == projectVerbName verb)
        require "the recovery offer kind differs" (handoffPayloadKind binding == RecoveryAdapterWire)
        require "the recovery offer phase differs" (handoffPhase binding == "teardown")
        require "the recovery offer token commitment is empty" (not (Text.null (handoffTokenCommitment binding)))
        require "the recovery offer specification differs" (handoffSpecDigest binding == stablePlanSnapshotSpecDigest snapshot)
        require "the recovery offer plan differs" (handoffPlanRevision binding == requestedPlanRevision input)
        require "the recovery offer parent differs" (handoffParentFrame binding == requestedParentFrame input)
        require "the recovery offer child differs" (handoffChildFrame binding == requestedChildFrame input)
        require "the recovery offer package digest differs" (handoffChildConfigDigest binding == childConfigDigest package)
        require "the recovery offer input differs" (bindingMatchesInput binding input)
        pure (renderBoundRecord preparedBytes bindingBytes)
      where
        (payload, token, bindingBytes) = handoffOfferFrames offer
        binding = handoffOfferBinding offer
        snapshot = renderSnapshot plan

    bindingMatchesInput binding input =
        and
            [ handoffSpecDigest binding == requestedSpecDigest input
            , handoffPayloadKind binding == requestedPayloadKind input
            , handoffPlanRevision binding == requestedPlanRevision input
            , handoffParentFrame binding == requestedParentFrame input
            , handoffChildFrame binding == requestedChildFrame input
            , handoffChildConfigDigest binding == requestedChildConfigDigest input
            , handoffPhase binding == requestedPhase input
            ]

    bindRecord session key preparedVersion preparedBytes boundBytes = do
        observed <- readProtectedRecord session key
        case observed of
            Left _ -> pure (Left (refusal "the bound record could not be read"))
            Right (Just record)
                | recordVersionWord (protectedRecordVersion record) >= 2
                , protectedRecordBytes record == boundBytes ->
                    pure (Right (protectedRecordVersion record))
                | recordVersionWord (protectedRecordVersion record) >= 2
                , Right _ <- parseBoundRecord preparedBytes (protectedRecordBytes record) ->
                    advanceBound session key (protectedRecordVersion record) boundBytes
                | exactRecord 1 preparedBytes record
                , protectedRecordVersion record == preparedVersion -> do
                    written <- compareAndSwapProtectedRecord session key (ExpectVersion preparedVersion) boundBytes
                    case written of
                        Left _ -> rereadBound session key 2 boundBytes
                        Right version
                            | recordVersionWord version /= 2 -> pure conflict
                            | otherwise -> rereadBound session key 2 boundBytes
                | otherwise -> pure conflict
            Right Nothing -> pure conflict
      where
        conflict = Left (refusal "the bound record conflicts")

    advanceBound session key current bytes
        | recordVersionWord current == maxBound = pure (Left (refusal "the bound record version is exhausted"))
        | otherwise = do
            written <- compareAndSwapProtectedRecord session key (ExpectVersion current) bytes
            case written of
                Left _ -> rereadBound session key (recordVersionWord current + 1) bytes
                Right version
                    | recordVersionWord version /= recordVersionWord current + 1 ->
                        pure (Left (refusal "the rebound record version differs"))
                    | otherwise -> rereadBound session key (recordVersionWord version) bytes

    rereadBound session key expectedVersion bytes = do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Right (Just record)
                | recordVersionWord (protectedRecordVersion record) == expectedVersion
                , protectedRecordBytes record == bytes ->
                    Right (protectedRecordVersion record)
            _ -> Left (refusal "the bound record readback differs")

    precheckRecord session key version bytes = do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left _ -> Left (refusal "the prepared record could not be read")
            Right (Just record)
                | protectedRecordVersion record == version
                , exactRecord 1 bytes record ->
                    Right ()
                | recordVersionWord (protectedRecordVersion record) >= 2
                , Right _ <- parseBoundRecord bytes (protectedRecordBytes record) ->
                    Right ()
            Right (Just _) -> Left (refusal "the prepared record is no longer current")
            Right Nothing -> Left (refusal "the prepared record is absent")

    require _ True = Right ()
    require detail False = Left (refusal detail)
    refusal = TeardownReverseDescentRefused
    refused prepared detail = pure (Left (refusal detail, prepared))

{- | Rehydrate one exact durable Bound descent without opening its token map.

The hidden signing capability and retained command are revalidated before one
read-only cursor/record entry. The fixed-unit callback runs only after unlock
and receives no offer, token, binding projection, or mutable store handle.
-}
withRehydratedBoundReverseDescentKernel ::
    RecoverySigningKernel ->
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    ( ReverseDescent
        (HandoffOffer scope brokerGeneration)
        scope
        planId
        parentFrame
        childFrame
        brokerGeneration
        verb
        descentId ->
      IO (Either Text ())
    ) ->
    IO
        ( Either
            (TeardownError, ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId)
            (Maybe (Either Text ()))
        )
{-# OPAQUE withRehydratedBoundReverseDescentKernel #-}
withRehydratedBoundReverseDescentKernel kernel =
    kernel `seq`
        consumeRecoverySigningKernel
            kernel
            ( \prepared use -> case prepared of
                PreparedReverseDescent _ _ _ _ _ cursor retained reauthorize _ _ _ _ _ _ store key _ preparedBytes -> do
                    replayed <- reauthorize
                    case replayed of
                        Left _ -> refused prepared "the exact command reservation is stale"
                        Right authority
                            | not (sameCommandAuthority store retained authority) ->
                                refused prepared "the replayed command authority differs"
                            | otherwise -> do
                                checked <- withProtectedEntry store $ \session -> do
                                    current <- validateCurrentLifecycleCursor session cursor
                                    case current of
                                        Left _ -> pure (Right (Left (refusal "the lifecycle cursor is stale")))
                                        Right () -> do
                                            observed <- readProtectedRecord session key
                                            forceProtectedResult (classifyRehydratedBoundRecordKernel preparedBytes observed)
                                case checked of
                                    Left _ -> refused prepared "the bound store entry failed"
                                    Right (Left failure) -> pure (Left (failure, prepared))
                                    Right (Right Nothing) -> pure (Right Nothing)
                                    Right (Right (Just (bindingBytes, version, boundBytes))) ->
                                        Right . Just <$> use (BoundReverseDescent prepared bindingBytes version boundBytes)
            )
  where
    refusal = TeardownReverseDescentRefused
    refused prepared detail = pure (Left (refusal detail, prepared))

{- | Classify the row a reverse descent's key holds, by type rather than by
refusal text: the exact version-one Prepared bytes are @Nothing@, a canonical
version-two-or-later Bound row yields its binding, version and bytes, and a read
failure, an absent row or any other row refuses.
-}
classifyRehydratedBoundRecordKernel ::
    ByteString ->
    Either ProtectedError (Maybe ProtectedRecord) ->
    Either TeardownError (Maybe (ByteString, RecordVersion, ByteString))
classifyRehydratedBoundRecordKernel expected observed = case observed of
    Right (Just record)
        | exactRecord 1 expected record -> Right Nothing
        | recordVersionWord (protectedRecordVersion record) >= 2 -> do
            binding <- parseBoundRecord expected (protectedRecordBytes record)
            pure (Just (binding, protectedRecordVersion record, protectedRecordBytes record))
    _ -> Left (TeardownReverseDescentRefused "the exact bound record is absent")

{- | Recover an already adopted child settlement without launching its frame.

An exact Prepared row or Bound row whose parent acknowledgement has not yet
reached Adopted returns @False@, allowing the live recovery exchange to resume.
An exact Adopted row replays its canonical completed report through the same
Bound observation verifier and returns @True@ only after the supplied
settlement continuation succeeds. Corrupt, refused, and failed terminal rows
remain refusals.
-}
withRehydratedSettledReverseDescentKernel ::
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    (SubtreeSettled scope planId childFrame verb -> IO (Either Text ())) ->
    IO
        ( Either
            (TeardownError, ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId)
            (Either Text Bool)
        )
{-# OPAQUE withRehydratedSettledReverseDescentKernel #-}
withRehydratedSettledReverseDescentKernel prepared use = do
    settledRef <- newIORef False
    rehydrated <- withRehydratedBoundReverseDescentKernel recoverySigningKernel prepared $ \bound ->
        case bound of
            BoundReverseDescent
                opened@(PreparedReverseDescent _ _ _ _ _ _ _ _ _ _ _ _ _ _ store _ _ _)
                binding
                version
                boundBytes -> do
                    adopted <- rehydrateAdoptedLifecycleReportKernel recoverySigningKernel store binding
                    case adopted of
                        Left failure -> pure (Left (Text.pack (handoffErrorMessage failure)))
                        Right Nothing -> pure (Right ())
                        Right (Just (adoptedBinding, report)) -> do
                            rebound <- rebindAdoptedReverseDescentKernel opened binding version boundBytes adoptedBinding
                            case rebound of
                                Left failure -> pure (Left failure)
                                Right exact -> replay exact report settledRef
    case rehydrated of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Right (Right False))
        Right (Just (Left failure)) -> pure (Right (Left failure))
        Right (Just (Right ())) -> Right . Right <$> readIORef settledRef
  where
    replay bound report settledRef =
        case eliminateLifecycleReport report forwardReport forwardReport forwardReport completed refused failed of
            Left failure -> pure (Left (Text.pack (handoffErrorMessage failure)))
            Right action -> action
      where
        completed binding _ observations _ verb =
            case teardownObservationsFromWire observations of
                Left failure -> pure (Left (Text.pack (teardownErrorMessage failure)))
                Right rows ->
                    withVerifiedBoundReverseDescentObservationsKernel
                        bound
                        binding
                        verb
                        rows
                        $ \settled -> do
                            used <- use settled
                            case used of
                                Left failure -> pure (Left failure)
                                Right () -> writeIORef settledRef True >> pure (Right ())
        refused _ _ _ detail _ = pure (Left ("the adopted reverse child refused: " <> detail))
        failed _ _ _ detail _ = pure (Left ("the adopted reverse child failed: " <> detail))
        forwardReport _ _ _ _ _ = pure (Left "the adopted reverse child retained a forward report")

{- | Rebind an exact Bound row to the binding its Adopted parent row carries.

The lifecycle cursor is checked inside the protected entry before the row is
read or replaced; a stale cursor, a changed row or an exhausted version refuses
without writing.
-}
rebindAdoptedReverseDescentKernel ::
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    ByteString ->
    RecordVersion ->
    ByteString ->
    ByteString ->
    IO
        ( Either
            Text
            (ReverseDescent (HandoffOffer scope brokerGeneration) scope planId parentFrame childFrame brokerGeneration verb descentId)
        )
rebindAdoptedReverseDescentKernel opened binding version boundBytes adoptedBinding
    | binding == adoptedBinding = pure (Right (BoundReverseDescent opened binding version boundBytes))
    | recordVersionWord version == maxBound = pure (Left "the adopted reverse descent version is exhausted")
    | otherwise = case opened of
        PreparedReverseDescent _ _ _ _ _ cursor _ _ _ _ _ _ _ _ store key _ preparedBytes -> do
            let reboundBytes = renderBoundRecord preparedBytes adoptedBinding
            entered <- withProtectedEntry store $ \session -> do
                current <- validateCurrentLifecycleCursor session cursor
                case current of
                    Left _ -> pure (Right (Left "the lifecycle cursor is stale"))
                    Right () -> do
                        observed <- readProtectedRecord session key
                        Right <$> case observed of
                            Left failure -> pure (Left (protectedErrorMessage failure))
                            Right (Just record)
                                | protectedRecordVersion record == version
                                , protectedRecordBytes record == boundBytes -> do
                                    written <-
                                        compareAndSwapProtectedRecord
                                            session
                                            key
                                            (ExpectVersion version)
                                            reboundBytes
                                    case written of
                                        Left failure -> pure (Left (protectedErrorMessage failure))
                                        Right reboundVersion -> do
                                            readback <- readProtectedRecord session key
                                            pure $ case readback of
                                                Left failure -> Left (protectedErrorMessage failure)
                                                Right (Just readbackRecord)
                                                    | protectedRecordVersion readbackRecord == reboundVersion
                                                    , recordVersionWord reboundVersion == recordVersionWord version + 1
                                                    , protectedRecordBytes readbackRecord == reboundBytes ->
                                                        Right (reboundVersion, reboundBytes)
                                                _ -> Left "the adopted rebound readback differs"
                            Right _ -> pure (Left "the bound reverse descent changed before adopted rebind")
            pure $ case entered of
                Left failure -> Left (protectedErrorMessage failure)
                Right (Left failure) -> Left failure
                Right (Right (reboundVersion, exactBytes)) ->
                    Right (BoundReverseDescent opened adoptedBinding reboundVersion exactBytes)

-- | Revalidate one Bound report coordinate without minting settlement proof.
withVerifiedBoundReverseDescentReportKernel ::
    ReverseDescent
        (HandoffOffer scope brokerGeneration)
        scope
        planId
        parentFrame
        childFrame
        brokerGeneration
        verb
        descentId ->
    ByteString ->
    Text ->
    IO (Either Text ()) ->
    IO (Either Text ())
{-# OPAQUE withVerifiedBoundReverseDescentReportKernel #-}
withVerifiedBoundReverseDescentReportKernel
    (BoundReverseDescent (PreparedReverseDescent _ verb _ _ _ cursor _ _ _ _ _ _ _ _ store key _ _) bindingBytes boundVersion boundBytes)
    observedBinding
    observedVerb
    use
        | observedBinding /= bindingBytes = pure (Left "the observed binding differs")
        | observedVerb /= projectVerbName verb = pure (Left "the observed reverse verb differs")
        | otherwise = do
            checked <- withProtectedEntry store $ \session -> do
                current <- validateCurrentLifecycleCursor session cursor
                case current of
                    Left _ -> pure (Right (Left "the retained lifecycle cursor is stale"))
                    Right () -> do
                        observed <- readProtectedRecord session key
                        forceProtectedResult (checkRecord observed)
            case checked of
                Left failure -> pure (Left (protectedErrorMessage failure))
                Right (Left failure) -> pure (Left failure)
                Right (Right ()) -> use
      where
        checkRecord observed = case observed of
            Right (Just record)
                | protectedRecordVersion record == boundVersion
                , protectedRecordBytes record == boundBytes ->
                    Right ()
            _ -> Left "the retained bound reverse descent is stale"

-- | Verify acknowledged terminal observations without exposing Bound state.
withVerifiedBoundReverseDescentObservationsKernel ::
    ReverseDescent
        (HandoffOffer scope brokerGeneration)
        scope
        planId
        parentFrame
        childFrame
        brokerGeneration
        verb
        descentId ->
    ByteString ->
    Text ->
    [(Text, TeardownOutcome)] ->
    (SubtreeSettled scope planId childFrame verb -> IO (Either Text ())) ->
    IO (Either Text ())
withVerifiedBoundReverseDescentObservationsKernel
    (BoundReverseDescent (PreparedReverseDescent _ verb _ _ _ cursor _ _ _ _ _ _ _ verify store key _ _) bindingBytes boundVersion boundBytes)
    observedBinding
    observedVerb
    observations
    use
        | observedBinding /= bindingBytes = pure (Left "the observed binding differs")
        | observedVerb /= projectVerbName verb = pure (Left "the observed reverse verb differs")
        | otherwise = do
            checked <- withProtectedEntry store $ \session -> do
                current <- validateCurrentLifecycleCursor session cursor
                case current of
                    Left _ -> pure (Right (Left "the retained lifecycle cursor is stale"))
                    Right () -> do
                        observed <- readProtectedRecord session key
                        forceProtectedResult (checkRecord observed)
            case checked of
                Left failure -> pure (Left (protectedErrorMessage failure))
                Right (Left failure) -> pure (Left failure)
                Right (Right settled) -> use settled
      where
        checkRecord observed = case observed of
            Right (Just record)
                | protectedRecordVersion record == boundVersion
                , protectedRecordBytes record == boundBytes ->
                    either (Left . Text.pack . teardownErrorMessage) Right (verify observations)
            _ -> Left "the retained bound reverse descent is stale"

forceProtectedResult ::
    Either failure result ->
    IO (Either ProtectedError (Either failure result))
forceProtectedResult outcome = case outcome of
    Left failure -> pure (Right (Left failure))
    Right result -> result `seq` pure (Right (Right result))

classifyPrepared :: ByteString -> ProtectedRecord -> Either TeardownError RecordVersion
classifyPrepared expected record =
    let version = protectedRecordVersion record
        bytes = protectedRecordBytes record
        bound = either (const Nothing) Just (parseBoundRecord expected bytes)
     in case classifyPreparedRecord expected (recordVersionWord version) bytes bound of
            Left detail -> Left (TeardownReverseDescentRefused detail)
            Right () -> Right version

parseBoundRecord :: ByteString -> ByteString -> Either TeardownError ByteString
parseBoundRecord expected raw = do
    (domain, afterDomain) <- takeBoundFrame raw
    (version, afterVersion) <- takeBoundFrame afterDomain
    (state, afterState) <- takeBoundFrame afterVersion
    (prepared, afterPrepared) <- takeBoundFrame afterState
    (binding, trailing) <- takeBoundFrame afterPrepared
    if and
        [ domain == "hostbootstrap/reverse-descent"
        , version == wordBytes 1
        , state == "bound"
        , prepared == expected
        , not (ByteString.null binding)
        , ByteString.null trailing
        , raw == renderBoundRecord prepared binding
        ]
        then Right binding
        else Left (TeardownReverseDescentRefused "the bound record is not canonical")
  where
    takeBoundFrame bytes =
        either
            (const (Left (TeardownReverseDescentRefused "the bound record is malformed")))
            Right
            (takeHandoffFrame bytes)

renderBoundRecord :: ByteString -> ByteString -> ByteString
renderBoundRecord prepared binding =
    ByteString.concat
        [ framedText "hostbootstrap/reverse-descent"
        , framedWord 1
        , framedText "bound"
        , frameWire prepared
        , frameWire binding
        ]

exactRecord :: Word64 -> ByteString -> ProtectedRecord -> Bool
exactRecord version bytes record =
    recordVersionWord (protectedRecordVersion record) == version
        && protectedRecordBytes record == bytes

sameCommandAuthority ::
    ProtectedStore ->
    CommandAuthority scope planId frame brokerGeneration verb phase ->
    CommandAuthority scope planId frame brokerGeneration verb phase ->
    Bool
sameCommandAuthority store expected observed =
    and
        [ invocationIdText (commandAuthorityInvocation expected)
            == invocationIdText (commandAuthorityInvocation observed)
        , commandAuthorityFrame expected == commandAuthorityFrame observed
        , brokerEpochWord (commandAuthorityEpoch expected) == brokerEpochWord (commandAuthorityEpoch observed)
        , projectVerbName (commandAuthorityVerb expected) == projectVerbName (commandAuthorityVerb observed)
        , lifecyclePhaseName (commandAuthorityPhase expected) == lifecyclePhaseName (commandAuthorityPhase observed)
        , commandAuthorityMatchesStore expected store
        , commandAuthorityMatchesStore observed store
        ]

framedText :: Text -> ByteString
framedText = frameWire . TextEncoding.encodeUtf8

framedWord :: Word64 -> ByteString
framedWord = frameWire . wordBytes

wordBytes :: Word64 -> ByteString
wordBytes = LazyByteString.toStrict . Builder.toLazyByteString . Builder.word64BE

verifyChildObservations ::
    TeardownPlan scope planId frame verb ->
    [(Text, TeardownOutcome)] ->
    Either TeardownError (SubtreeSettled scope planId frame verb)
verifyChildObservations projection observations =
    case openTeardownForest projection of
        Left failure -> Left failure
        Right opened
            | map fst observations /= teardownForestOutstanding opened -> mismatch opened observations
            | any failed observations -> Left (TeardownNonTerminalObservations observations)
            | otherwise -> replay opened observations
  where
    failed (_, TeardownFailed _) = True
    failed _ = False
    mismatch forest rows =
        Left (TeardownTerminalObservationsMismatch (teardownForestOutstanding forest) (map fst rows))
    replay forest remaining =
        eliminateTeardownProgress
            (nextTeardownWork forest)
            (\completed -> if null remaining then verifySubtreeSettled projection completed else mismatch forest remaining)
            ( \point ->
                withTeardownAuthorization
                    point
                    (\preDescent -> replay (attemptPreDescentStep preDescent TeardownReleased) remaining)
                    ( \_ work ->
                        eliminateTeardownWork
                            work
                            ( \local -> case remaining of
                                (key, outcome) : rest
                                    | key == localWorkKey local -> replay (attemptLocalWork local outcome) rest
                                _ -> mismatch forest remaining
                            )
                            ( \descent ->
                                withDescentWorkSubtree descent $ \childProjection ->
                                    case openTeardownForest childProjection of
                                        Left failure -> Left failure
                                        Right childForest -> do
                                            let childCount = length (teardownForestOutstanding childForest)
                                                (childRows, rest) = splitAt childCount remaining
                                            childSettled <- verifyChildObservations childProjection childRows
                                            successor <- settleDescentWork descent childSettled
                                            replay successor rest
                            )
                    )
            )
