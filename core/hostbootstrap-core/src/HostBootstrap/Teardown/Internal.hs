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
module HostBootstrap.Teardown.Internal
    ( ReverseDescent
    , withReverseDescentLiftContextKernel
    , withReverseDescentProcessInputsKernel
    , withPreparedReverseForestKernel
    , withPreparedReverseAdmissionsKernel
    , renderPreparedReverseTerminalOriginKernel
    , withPreparedReverseDescentKernel
    , withBoundReverseDescentKernel
    , withRehydratedBoundReverseDescentKernel
    , withRehydratedAdoptedReverseDescentKernel
    , withVerifiedBoundReverseDescentReportKernel
    , withVerifiedBoundReverseDescentObservationsKernel
    , withVerifiedReverseAdapterKernel
    )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority
import HostBootstrap.Authority.Kernel (rootAuthorityStoreIdentity)
import HostBootstrap.Handoff
import HostBootstrap.Handoff.Internal (RecoverySigningKernel, consumeRecoverySigningKernel)
import HostBootstrap.Handoff.Recovery
    ( recoveryChildPackageFromWireKernel
    , recoveryChildPackageKernel
    , renderRecoveryChildPackageKernel
    , withRecoveryChildPackageKernel
    )
import HostBootstrap.Lifecycle.Context (ValidatedLifecycleContext)
import HostBootstrap.Lifecycle.Context.Internal (withValidatedRootLifecycleContext)
import HostBootstrap.Lifecycle.Mode
import HostBootstrap.Lifecycle.RootedPlan
    ( RootedPlanCatalog
    , withRootedPlanCatalogEdgeKernel
    )
import HostBootstrap.Lift.Context (LiftContext)
import qualified HostBootstrap.Lifecycle.Plan as Plan
import HostBootstrap.ProjectPlan
import HostBootstrap.ProjectPlan.Frame
import HostBootstrap.Protected
import HostBootstrap.Teardown

{- | One parent-local reverse descent through its durable lifecycle states.

Prepared retains the sealed root entry, original forest continuation,
canonical adapter, verifier, and durable readback. Bound nests that exact
package with canonical binding bytes and its exact successor record; the
live offer remains lexical to the relay callback that attached it.
-}
data ReverseDescent
    state scope planId parentFrame childFrame brokerGeneration verb descentId
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
        ReverseDescent (HandoffOffer scope brokerGeneration)
            scope planId parentFrame childFrame brokerGeneration verb descentId

type role ReverseDescent nominal nominal nominal nominal nominal nominal nominal nominal

{- | Derive the exact plan-owned launch context retained by one reverse edge. -}
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
                    Just (child, context)
                        | child /= expectedChild ->
                            pure (Left "the plan-owned lift context enters a different child")
                        | teardownPlanFrameId subtree /= expectedChild ->
                            pure (Left "the retained descent subtree opens at a different child")
                        | teardownPlanVerbName subtree /= projectVerbName verb ->
                            pure (Left "the retained descent subtree has a different reverse verb")
                        | otherwise -> context `seq` use context

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

    admitRecovery :: forall planDigest recoveryParent recoveryChild.
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
projection. Phase 13's frozen neutral constructor then joins the two into the
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
        case
            withValidatedRootLifecycleContext
                lifecycleContext
                (\_ store current frame _ -> prepare store current frame)
        of
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
                                         in admitPrepared store current frame childProjection snapshot parent child expected
                                                adapter childConfig configDigest package packageDigest invocation input bytes

            catalogPackage parent child expected = do
                (childPlanDigest, childConfig, configDigest) <-
                    withRootedPlanCatalogEdgeKernel catalog parent child selectChildConfig
                let adapter = renderReverseAdapter childPlanDigest verb parent child expected
                package <- recoveryChildPackageKernel childConfig adapter
                pure (childPlanDigest, adapter, childConfig, configDigest, renderRecoveryChildPackageKernel package)

            selectChildConfig _parentCurrent _plan binding _current _raw _route payload configDigest _payloadDigest _keys =
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
                                                                            root verb plan lifecycleContext journal cursor
                                                                            retained reauthorize descent input package
                                                                            packageDigest expected
                                                                            (verifyChildObservations childProjection)
                                                                            store key version bytes
                                                                        )

            validate store current frame childProjection snapshot parent child expected adapter childConfig configDigest package preparedBytes = do
                require "the verb and lifecycle phase cannot prepare cleanup descent" $
                    case verb of
                        ProjectUp -> retainedPhase == "execute"
                        ProjectDown -> retainedPhase == "teardown"
                        ProjectDestroy -> retainedPhase == "teardown"
                require "the root verb differs" (verbName == projectVerbName (rootAuthorityVerb root))
                require "the journal verb differs" (verbName == acquisitionJournalRootVerb journal)
                require "the cursor verb differs" (verbName == projectVerbName (lifecycleCursorVerb cursor))
                require "the command verb differs" (verbName == projectVerbName (commandAuthorityVerb retained))
                require "the cursor and command phases differ" (lifecyclePhaseName (lifecycleCursorPhase cursor) == retainedPhase)
                require "the project identity differs" (projectPlanProjectName plan == rootAuthorityProjectName root)
                require "the protected store differs" (storeIdentity == rootAuthorityStoreIdentity root)
                require "the plan store differs" (Plan.projectPlanProfileStoreIdentityKernel plan == storeIdentity)
                require "the plan scope differs" (Plan.projectPlanProfileNameKernel plan == acquisitionJournalStableScope journal)
                require "the plan digest differs" (stablePlanSnapshotDigest snapshot == acquisitionJournalSnapshotDigest journal)
                require "the canonical plan is empty" (not (ByteString.null (stablePlanSnapshotBytes snapshot)))
                require "the broker generation differs" (epoch == acquisitionJournalBrokerGeneration journal)
                require "the plan broker generation differs" (epoch == Plan.projectPlanProfileEpochKernel plan)
                require "the command broker generation differs" (epoch == brokerEpochWord (commandAuthorityEpoch retained))
                require "the context current frame differs from its project frame" (currentFrameId current == projectFrameId frame)
                require "the cursor frame differs from the root context" (lifecycleCursorFrame cursor == currentFrameId current)
                require "the command frame differs from the root context" (commandAuthorityFrame retained == currentFrameId current)
                require "the child projection opening frame differs" (teardownPlanFrameId childProjection == child)
                require "the child projection verb differs" (teardownPlanVerbName childProjection == verbName)
                require "the parent and child frames are equal" (parent /= child)
                require "the parent frame is outside the plan" (topologyContainsFrame (topology plan) parent)
                require "the child frame is outside the plan" (topologyContainsFrame (topology plan) child)
                require "the descent is not the exact immediate topology edge" $
                    [ edge
                    | edge@(_, edgeChild) <- topologyParentEdges (topology plan)
                    , edgeChild == child
                    ]
                        == [(parent, child)]
                require "the cursor and command origins differ" (lifecycleCursorMatchesCommandAuthority retained cursor)
                require "the command belongs to a different store" (commandAuthorityMatchesStore retained store)
                require "the acquisition run is empty" (not (Text.null (acquisitionJournalRunLease journal)))
                require "the command invocation is empty" (not (Text.null invocation))
                require "the acquisition version is invalid" (acquisitionJournalRecordVersion journal > 0)
                require "the cursor version is invalid" (lifecycleCursorRecordVersion cursor > 0)
                require "the child observation order is empty" (not (null expected))
                require "the child observation order contains duplicates" (length expected == length (nub expected))
                require "the recovery adapter is empty" (not (ByteString.null adapter))
                require "the recovery adapter exceeds the handoff bound" (fromIntegral (ByteString.length adapter) <= maxWireBytes)
                require "the catalog child configuration is empty" (not (ByteString.null childConfig))
                require "the catalog child configuration digest differs" (configDigest == childConfigDigest childConfig)
                require "the recovery package does not carry the exact catalog child configuration and adapter" (package == renderedPackage)
                require "the recovery package exceeds the handoff bound" (fromIntegral (ByteString.length package) <= maxWireBytes)
                require "the recovery package and child configuration digests are conflated" (childConfigDigest package /= configDigest)
                require "the prepared record exceeds the handoff bound" (fromIntegral (ByteString.length preparedBytes) <= maxWireBytes)
              where
                storeIdentity = protectedStoreIdentityText (protectedStoreIdentity store)
                epoch = brokerEpochWord (rootAuthorityEpoch root)
                verbName = projectVerbName verb
                retainedPhase = lifecyclePhaseName (commandAuthorityPhase retained)
                invocation = invocationIdText (commandAuthorityInvocation retained)
                renderedPackage =
                    either
                        (const ByteString.empty)
                        renderRecoveryChildPackageKernel
                        (recoveryChildPackageKernel childConfig adapter)

            keyFor invocation adapterDigest =
                case
                    mkRecordKey
                        ( "reverse-descent."
                            <> recoveryWireDigest (TextEncoding.encodeUtf8 invocation)
                            <> "."
                            <> adapterDigest
                        )
                of
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

            require _ True = Right ()
            require detail False = Left (refusal detail)
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
    ( ReverseDescent (HandoffOffer scope brokerGeneration)
        scope planId parentFrame childFrame brokerGeneration verb descentId ->
      HandoffOffer scope brokerGeneration ->
      IO (Either failure ())
    ) ->
    IO (Either
        (TeardownError, ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId)
        (Either failure ()))
{-# OPAQUE withBoundReverseDescentKernel #-}
withBoundReverseDescentKernel kernel =
    kernel `seq` consumeRecoverySigningKernel kernel (\prepared open use -> case prepared of
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
                                                     in Right <$> use (BoundReverseDescent prepared bindingBytes version boundBytes) offer)
  where
    validateOffer root verb plan journal input package preparedBytes offer = do
        require "the recovery offer payload differs" (payload == package)
        require "the recovery offer token is empty" (not (ByteString.null token))
        require "the recovery offer binding is not canonical" (bindingBytes == renderHandoffBinding binding)
        require "the recovery offer project differs" (handoffInstalledProject binding == rootAuthorityProjectName root)
        require
            "the recovery offer scope differs"
            ( handoffScope binding
                == if acquisitionJournalStableScope journal == "production"
                    then "Production"
                    else acquisitionJournalStableScope journal
            )
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

    bindingMatchesInput binding input = and
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
                | exactRecord 2 boundBytes record -> pure (Right (protectedRecordVersion record))
                | exactRecord 1 preparedBytes record
                , protectedRecordVersion record == preparedVersion -> do
                    written <- compareAndSwapProtectedRecord session key (ExpectVersion preparedVersion) boundBytes
                    case written of
                        Left _ -> rereadBound session key boundBytes
                        Right version
                            | recordVersionWord version /= 2 -> pure conflict
                            | otherwise -> rereadBound session key boundBytes
                | otherwise -> pure conflict
            Right Nothing -> pure conflict
      where
        conflict = Left (refusal "the bound record conflicts")

    rereadBound session key bytes = do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Right (Just record)
                | exactRecord 2 bytes record -> Right (protectedRecordVersion record)
            _ -> Left (refusal "the bound record readback differs")

    precheckRecord session key version bytes = do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left _ -> Left (refusal "the prepared record could not be read")
            Right (Just record)
                | protectedRecordVersion record == version
                , exactRecord 1 bytes record -> Right ()
                | recordVersionWord (protectedRecordVersion record) == 2
                , Right _ <- parseBoundRecord bytes (protectedRecordBytes record) -> Right ()
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
    ( ReverseDescent (HandoffOffer scope brokerGeneration)
        scope planId parentFrame childFrame brokerGeneration verb descentId ->
      IO (Either Text ())
    ) ->
    IO (Either
        (TeardownError, ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId)
        (Either Text ()))
{-# OPAQUE withRehydratedBoundReverseDescentKernel #-}
withRehydratedBoundReverseDescentKernel kernel =
    kernel `seq` consumeRecoverySigningKernel kernel (\prepared use -> case prepared of
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
                                    forceProtectedResult (rehydrateRecord preparedBytes observed)
                        case checked of
                            Left _ -> refused prepared "the bound store entry failed"
                            Right (Left failure) -> pure (Left (failure, prepared))
                            Right (Right (bindingBytes, version, boundBytes)) ->
                                Right <$> use (BoundReverseDescent prepared bindingBytes version boundBytes))
  where
    rehydrateRecord expected observed = case observed of
        Right (Just record)
            | recordVersionWord (protectedRecordVersion record) == 2 -> do
                binding <- parseBoundRecord expected (protectedRecordBytes record)
                pure (binding, protectedRecordVersion record, protectedRecordBytes record)
        _ -> Left (refusal "the exact bound record is absent")
    refusal = TeardownReverseDescentRefused
    refused prepared detail = pure (Left (refusal detail, prepared))

{- | Rehydrate Bound descent and its exact parent Adopted acknowledgement.

The Bound record and lifecycle cursor are checked first. The retained store is
then used only for the read-only Adopted verifier; no token, offer, mutation,
process, or local teardown action is reopened.
-}
withRehydratedAdoptedReverseDescentKernel ::
    RecoverySigningKernel ->
    ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId ->
    ByteString ->
    ( ReverseDescent (HandoffOffer scope brokerGeneration)
        scope planId parentFrame childFrame brokerGeneration verb descentId ->
      ByteString ->
      IO (Either Text ())
    ) ->
    IO (Either
        (TeardownError, ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId)
        (Either Text ()))
{-# OPAQUE withRehydratedAdoptedReverseDescentKernel #-}
withRehydratedAdoptedReverseDescentKernel kernel prepared report use =
    withRehydratedBoundReverseDescentKernel kernel prepared $ \bound ->
        case bound of
            BoundReverseDescent
                (PreparedReverseDescent _ _ _ _ _ _ _ _ _ _ _ _ _ _ store _ _ _)
                binding _ _ -> do
                    adopted <-
                        rehydrateAdoptedLifecycleAcknowledgementKernel
                            kernel store binding report (use bound)
                    pure $ either (Left . Text.pack . handoffErrorMessage) id adopted

{- | Revalidate one Bound report coordinate without minting settlement proof. -}
withVerifiedBoundReverseDescentReportKernel ::
    ReverseDescent (HandoffOffer scope brokerGeneration)
        scope planId parentFrame childFrame brokerGeneration verb descentId ->
    ByteString ->
    Text ->
    IO (Either Text ()) ->
    IO (Either Text ())
{-# OPAQUE withVerifiedBoundReverseDescentReportKernel #-}
withVerifiedBoundReverseDescentReportKernel
    (BoundReverseDescent (PreparedReverseDescent _ verb _ _ _ cursor _ _ _ _ _ _ _ _ store key _ _) bindingBytes boundVersion boundBytes)
    observedBinding observedVerb use
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
                , protectedRecordBytes record == boundBytes -> Right ()
            _ -> Left "the retained bound reverse descent is stale"

{- | Verify acknowledged terminal observations without exposing Bound state. -}
withVerifiedBoundReverseDescentObservationsKernel ::
    ReverseDescent (HandoffOffer scope brokerGeneration)
        scope planId parentFrame childFrame brokerGeneration verb descentId ->
    ByteString ->
    Text ->
    [(Text, TeardownOutcome)] ->
    (SubtreeSettled scope planId childFrame verb -> IO (Either Text ())) ->
    IO (Either Text ())
withVerifiedBoundReverseDescentObservationsKernel
    (BoundReverseDescent (PreparedReverseDescent _ verb _ _ _ cursor _ _ _ _ _ _ _ verify store key _ _) bindingBytes boundVersion boundBytes)
    observedBinding observedVerb observations use
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
classifyPrepared expected record
    | exactRecord 1 expected record = Right (protectedRecordVersion record)
    | recordVersionWord (protectedRecordVersion record) == 2
    , Right _ <- parseBoundRecord expected (protectedRecordBytes record) = Right (protectedRecordVersion record)
    | otherwise = Left (TeardownReverseDescentRefused "a conflicting prepared record exists")

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
renderBoundRecord prepared binding = ByteString.concat
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
sameCommandAuthority store expected observed = and
    [ invocationIdText (commandAuthorityInvocation expected)
        == invocationIdText (commandAuthorityInvocation observed)
    , commandAuthorityFrame expected == commandAuthorityFrame observed
    , brokerEpochWord (commandAuthorityEpoch expected) == brokerEpochWord (commandAuthorityEpoch observed)
    , projectVerbName (commandAuthorityVerb expected) == projectVerbName (commandAuthorityVerb observed)
    , lifecyclePhaseName (commandAuthorityPhase expected) == lifecyclePhaseName (commandAuthorityPhase observed)
    , commandAuthorityMatchesStore expected store
    , commandAuthorityMatchesStore observed store
    ]


{- | Verify one canonical reverse adapter against its exact local projection.

The supplied current frame must be the child of exactly one plan topology
edge. Only Down and Destroy projections are accepted, and the continuation
receives no bytes or caller-selected topology.
-}
withVerifiedReverseAdapterKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId localFrame ->
    ProjectVerb verb ->
    ByteString ->
    (TeardownPlan scope planId localFrame verb -> result) ->
    Either TeardownError result
withVerifiedReverseAdapterKernel plan current verb observed use =
    case verb of
        ProjectUp -> Left (refusal "project up has no reverse adapter")
        ProjectDown -> verify
        ProjectDestroy -> verify
  where
    verify =
        case parentFrames of
            [parent] ->
                case openTeardownForest projection of
                    Left failure -> Left failure
                    Right forest
                        | length expected /= length (nub expected) ->
                            Left (refusal "the adapter operation order contains duplicates")
                        | fromIntegral (ByteString.length canonical) > maxWireBytes ->
                            Left (refusal "the canonical adapter exceeds the handoff bound")
                        | observed /= canonical ->
                            Left (refusal "the supplied reverse adapter is not canonical")
                        | otherwise -> Right (use projection)
                      where
                        expected = teardownForestOutstanding forest
                        canonical = renderReverseAdapter planDigest verb parent child expected
            _ -> Left (refusal "the current frame is not one exact topology child")
    child = currentFrameId current
    parentFrames =
        [ parent
        | (parent, edgeChild) <- topologyParentEdges (topology plan)
        , edgeChild == child
        ]
    projection = teardownPlan plan current verb
    planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
    refusal = TeardownReverseDescentRefused

renderReverseAdapter :: Text -> ProjectVerb verb -> Text -> Text -> [Text] -> ByteString
renderReverseAdapter planDigest closedVerb parent child expected =
    ByteString.concat
        ( [ framedText "hostbootstrap/reverse-descent-adapter"
          , framedWord 1
          , framedText planDigest
          , framedText parent
          , framedText child
          , framedText (projectVerbName closedVerb)
          , framedText "teardown"
          , framedWord (fromIntegral (length expected))
          ]
            ++ map framedText expected
            ++ [ framedWord 3
               , framedText "released"
               , framedText "foreign-retained"
               , framedText "refused"
               ]
        )

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
                withTeardownAuthorization point
                    (\preDescent -> replay (attemptPreDescentStep preDescent TeardownReleased) remaining)
                    ( \_ work ->
                        eliminateTeardownWork work
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
