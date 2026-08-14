{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Package-private representation of child plan authority.

Only the child-plan admission facade can mint this value.  Keeping the
constructor in an unexposed module prevents transport verification by itself
from becoming plan or command authority.
-}
module HostBootstrap.ProjectPlan.Child.Internal
    ( ChildPlanAuthority
    , AuthenticatedChildCursor
    , AuthorizedChildCursor
    , mintChildPlanAuthorityKernel
    , childPlanAuthorityBindingKernel
    , withAuthenticatedChildCursor
    , authorizeAuthenticatedChildCursorKernel
    , authorizedChildCursorFrameNameKernel
    , authorizedChildCursorVerbNameKernel
    , renderForwardTerminalOriginKernel
    , runAuthorizedChildCursorKernel
    , withReceivedRecoveryChildOriginKernel
    )
where

import Control.Exception (SomeException, displayException, fromException)
import Control.Exception.Safe (try)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority
    ( AuthorityError (AuthorityMalformedBinding)
    , CommandAuthority
    , ExecutePhase
    , LifecyclePhase (Execute, Teardown)
    , ProjectVerb (ProjectDestroy, ProjectDown, ProjectUp)
    , TeardownPhase
    , VerbUp
    , brokerEpochWord
    , authorityErrorMessage
    , commandAuthorityEpoch
    , commandAuthorityFrame
    , commandAuthorityInvocation
    , commandAuthorityMatchesStore
    , commandAuthorityPhase
    , commandAuthorityVerb
    , invocationIdText
    , lifecyclePhaseName
    , projectVerbName
    )
import HostBootstrap.Authority.Kernel
    ( childCommandReservationKernel
    )
import HostBootstrap.Authority.ProjectPlan.Internal
    ( ChildRecoveryOrigin
    , withChildRecoveryOriginKernel
    )
import HostBootstrap.Chain (runChainFromFrame)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Config.Class (ProjectCfg)
import HostBootstrap.Config.Schema
    ( ValidatedConfig
    , VerifiedConfigHandoff
    , validatedConfigDigest
    , validatedConfigSpecDigest
    , verifiedConfigHandoffBinding
    , verifiedConfigHandoffPhase
    )
import HostBootstrap.Handoff
    ( HandoffBinding
    , HandoffPayloadKind (RecoveryAdapterWire)
    , handoffBrokerGeneration
    , handoffChildConfigDigest
    , handoffChildFrame
    , handoffInstalledProject
    , handoffPhase
    , handoffPayloadKind
    , handoffPlanRevision
    , handoffParentFrame
    , handoffScope
    , handoffSpecDigest
    , handoffStoreIdentity
    , handoffTokenCommitment
    , handoffVerb
    , recoveryWireDigest
    , renderHandoffBinding
    , verifiedHandoffBinding
    )
import HostBootstrap.Handoff.Receiver (ReceivedRecoveryDescent)
import HostBootstrap.Handoff.Receiver.Internal
    ( receivedEdgeHandoff
    , withReceivedRecoveryDescent
    )
import HostBootstrap.Harness
    ( SafetyRefusal (SafetyRefusal)
    , safetyRefusalMarker
    )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Context
    ( ValidatedLifecycleContext
    , lifecycleContextErrorMessage
    , withValidatedLifecycleContext
    )
import HostBootstrap.Lifecycle.Context.Internal
    ( withValidatedNestedLifecycleContext
    )
import HostBootstrap.Lifecycle.Mode
    ( AcquisitionJournal
    , LifecycleCursor
    , LifecycleError
    , lifecycleErrorMessage
    , reopenAuthenticatedChildCursorKernel
    , reopenAuthenticatedRecoveryChildCursorKernel
    , withAcquisitionJournalPhase
    , withTeardownLifecycleCursor
    )
import HostBootstrap.Lift (SelfRef)
import HostBootstrap.Lifecycle.Session
    ( SessionError (SessionAcquisitionBindingMismatch)
    , acquisitionJournalBrokerGeneration
    , acquisitionJournalRecordVersion
    , acquisitionJournalRootVerb
    , acquisitionJournalSnapshotDigest
    , acquisitionJournalStableScope
    , lifecycleCursorFrame
    , lifecycleCursorMatchesCommandAuthority
    , lifecycleCursorPhase
    , lifecycleCursorRecordVersion
    , lifecycleCursorVerb
    , reserveCurrentLifecycleCommandKernel
    )
import HostBootstrap.Lifecycle.Plan
    ( acquisitionJournalAdmissionKernel
    , canonicalPlanSnapshotConfigDigest
    , canonicalPlanSnapshotDigest
    , canonicalPlanSnapshotSpecDigest
    , planDigestBindingDigestKernel
    , projectPlanCanonicalSnapshotKernel
    , projectPlanProfileEpochKernel
    , projectPlanProfileNameKernel
    , projectPlanProfileProjectNameKernel
    , projectPlanProfileStoreIdentityKernel
    , projectPlanValidatedConfigKernel
    , withChildProjectPlanKernel
    )
import HostBootstrap.ProjectPlan
    ( PlanDraft
    , ProjectPlan
    , renderSnapshot
    , stablePlanSnapshotConfigDigest
    , stablePlanSnapshotDigest
    , stablePlanSnapshotSpecDigest
    , topology
    , topologyContainsFrame
    , topologyParentEdges
    , topologyParentFrame
    )
import HostBootstrap.ProjectPlan.Frame
    ( currentFrameId
    , projectFrameId
    , validatedContextValue
    )
import HostBootstrap.ProjectPlan.Snapshot (PlanDigestBinding)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.Protected
    ( ProtectedStore
    , protectedStoreIdentity
    , protectedStoreIdentityText
    )
import HostBootstrap.Teardown
    ( teardownPlanFrameId
    , teardownPlanVerbName
    )
import HostBootstrap.Teardown.Internal (withVerifiedReverseAdapterKernel)

data ChildPlanAuthority
    scope specDigest planDigest brokerGeneration parentFrame childFrame
    planId configId verb phase
    where
    ChildPlanAuthority ::
        HandoffBinding scope brokerGeneration ->
        LifecyclePhase phase ->
        ChildPlanAuthority
            scope specDigest planDigest brokerGeneration parentFrame childFrame
            planId configId verb phase

type role ChildPlanAuthority nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

instance
    Show
        ( ChildPlanAuthority
            scope specDigest planDigest brokerGeneration parentFrame childFrame
            planId configId verb phase
        )
    where
    show (ChildPlanAuthority binding phase) =
        "ChildPlanAuthority " <> show binding <> " " <> show phase

mintChildPlanAuthorityKernel ::
    VerifiedConfigHandoff
        scope planDigest brokerGeneration parentFrame childFrame configId verb phase ->
    ProjectPlan scope specDigest planId configId cfg ->
    PlanDigestBinding scope specDigest planDigest planId ->
    ChildPlanAuthority
        scope specDigest planDigest brokerGeneration parentFrame childFrame
        planId configId verb phase
mintChildPlanAuthorityKernel handoff plan binding =
    plan
        `seq` binding
        `seq` ChildPlanAuthority
            (verifiedConfigHandoffBinding handoff)
            (verifiedConfigHandoffPhase handoff)

childPlanAuthorityBindingKernel ::
    ChildPlanAuthority
        scope specDigest planDigest brokerGeneration parentFrame childFrame
        planId configId verb phase ->
    HandoffBinding scope brokerGeneration
childPlanAuthorityBindingKernel (ChildPlanAuthority binding _) = binding

childPlanAuthorityPhaseKernel ::
    ChildPlanAuthority
        scope specDigest planDigest brokerGeneration parentFrame childFrame
        planId configId verb phase ->
    LifecyclePhase phase
childPlanAuthorityPhaseKernel (ChildPlanAuthority _ phase) = phase

data AuthenticatedChildCursor
    scope specDigest planDigest brokerGeneration parentFrame
    planId configId childFrame verb phase
    where
    AuthenticatedChildCursor ::
        VerifiedConfigHandoff
            scope planDigest brokerGeneration parentFrame signedChildFrame
            configId VerbUp phase ->
        ChildPlanAuthority
            scope specDigest planDigest brokerGeneration parentFrame signedChildFrame
            planId configId VerbUp phase ->
        ProjectPlan scope specDigest planId configId cfg ->
        PlanDigestBinding scope specDigest planDigest planId ->
        ValidatedLifecycleContext scope specDigest planId configId childFrame ->
        AcquisitionJournal scope planId brokerGeneration ->
        LifecycleCursor scope planId childFrame brokerGeneration VerbUp phase ->
        AuthenticatedChildCursor
            scope specDigest planDigest brokerGeneration parentFrame
            planId configId childFrame VerbUp phase

type role AuthenticatedChildCursor nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

{- | Exact child package after one durable command reservation.

The constructor retains the whole authenticated cursor package and its matching
command authority as one value.  Neither member has an independent eliminator.
-}
data AuthorizedChildCursor
    scope specDigest planDigest brokerGeneration parentFrame
    planId configId childFrame verb phase
    where
    AuthorizedExecuteChildCursor ::
        AuthenticatedChildCursor
            scope specDigest planDigest brokerGeneration parentFrame
            planId configId childFrame VerbUp ExecutePhase ->
        CommandAuthority
            scope planId childFrame brokerGeneration VerbUp ExecutePhase ->
        AuthorizedChildCursor
            scope specDigest planDigest brokerGeneration parentFrame
            planId configId childFrame VerbUp ExecutePhase

    AuthorizedTeardownChildCursor ::
        AuthorizedChildCursor
            scope specDigest planDigest brokerGeneration parentFrame
            planId configId childFrame VerbUp ExecutePhase ->
        LifecycleCursor
            scope planId childFrame brokerGeneration VerbUp TeardownPhase ->
        AuthorizedChildCursor
            scope specDigest planDigest brokerGeneration parentFrame
            planId configId childFrame VerbUp TeardownPhase

type role AuthorizedChildCursor nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

withAuthenticatedChildCursor ::
    VerifiedConfigHandoff
        scope planDigest brokerGeneration parentFrame signedChildFrame
        configId VerbUp phase ->
    ChildPlanAuthority
        scope specDigest planDigest brokerGeneration parentFrame signedChildFrame
        planId configId VerbUp phase ->
    ProjectPlan scope specDigest planId configId cfg ->
    PlanDigestBinding scope specDigest planDigest planId ->
    ValidatedLifecycleContext scope specDigest planId configId childFrame ->
    ( AuthenticatedChildCursor
        scope specDigest planDigest brokerGeneration parentFrame
        planId configId childFrame VerbUp phase ->
      IO result
    ) ->
    IO (Either LifecycleError result)
withAuthenticatedChildCursor handoff authority plan digestBinding lifecycleContext use =
    case withValidatedNestedLifecycleContext lifecycleContext (\_ store _ frame _ -> (store, frame)) of
        Left failure -> pure (Left (contextFailure failure))
        Right (store, frame) -> enter store frame
  where
    signed = verifiedConfigHandoffBinding handoff
    retained = childPlanAuthorityBindingKernel authority
    retainedPhase = childPlanAuthorityPhaseKernel authority
    enter store frame = case validateLocal frame of
        Left failure -> pure (Left failure)
        Right () ->
            reopenAuthenticatedChildCursorKernel
                acquisitionJournalAdmissionKernel store signed plan digestBinding frame retainedPhase
                (\journal cursor ->
                    use
                        ( AuthenticatedChildCursor
                            handoff authority plan digestBinding lifecycleContext journal cursor
                        )
                )

    validateLocal frame = do
        require "handoff binding" (signed == retained)
        requireText "project frame" child (projectFrameId frame)
        case topologyParentFrame (topology plan) child of
            Just parent -> requireText "parent frame" (handoffParentFrame signed) parent
            Nothing -> mismatch "parent frame" (handoffParentFrame signed) "absent"
      where
        child = handoffChildFrame signed
    require field condition
        | condition = Right ()
        | otherwise = mismatch field "exact" "different"
    requireText field expected observed
        | expected == observed = Right ()
        | otherwise = mismatch field expected observed
    mismatch field expected observed =
        Left (SessionAcquisitionBindingMismatch field expected observed)
    contextFailure failure =
        SessionAcquisitionBindingMismatch
            "nested lifecycle context"
            "valid nested context"
            (Text.pack (lifecycleContextErrorMessage failure))

{- | Reserve exactly one authenticated child Up/Execute invocation.

Pattern matching forces the whole authenticated package before any retained
evidence is inspected or the protected reservation bridge is entered.  Every
comparison is pure; the only mutation-capable call is the final exact
cursor-bound reservation.
-}
authorizeAuthenticatedChildCursorKernel ::
    AuthenticatedChildCursor
        scope specDigest planDigest brokerGeneration parentFrame
        planId configId childFrame VerbUp ExecutePhase ->
    IO
        ( Either
            AuthorityError
            ( AuthorizedChildCursor
                scope specDigest planDigest brokerGeneration parentFrame
                planId configId childFrame VerbUp ExecutePhase
            )
        )
authorizeAuthenticatedChildCursorKernel
    authenticated@(
        AuthenticatedChildCursor
            handoff
            authority
            plan
            digestBinding
            lifecycleContext
            journal
            cursor
        ) =
        case
            withValidatedNestedLifecycleContext
                lifecycleContext
                (\_root _store _current frame validated -> validateRetained frame validated)
        of
            Left failure -> pure (Left (contextAuthorityFailure failure))
            Right (Left failure) -> pure (Left failure)
            Right (Right ()) -> do
                reserved <-
                    reserveCurrentLifecycleCommandKernel
                        journal
                        cursor
                        ( childCommandReservationKernel
                            signedProject
                            signedStore
                            signedGeneration
                            ProjectUp
                            canonicalPlanDigest
                            Execute
                            signedChild
                        )
                pure (AuthorizedExecuteChildCursor authenticated <$> reserved)
      where
        signed = verifiedConfigHandoffBinding handoff
        retained = childPlanAuthorityBindingKernel authority
        retainedPhase = childPlanAuthorityPhaseKernel authority
        signedProject = handoffInstalledProject signed
        signedStore = handoffStoreIdentity signed
        signedGeneration = handoffBrokerGeneration signed
        signedChild = handoffChildFrame signed
        canonical = projectPlanCanonicalSnapshotKernel plan
        canonicalSpecDigest = canonicalPlanSnapshotSpecDigest canonical
        canonicalConfigDigest = canonicalPlanSnapshotConfigDigest canonical
        canonicalPlanDigest = canonicalPlanSnapshotDigest canonical
        retainedConfig = projectPlanValidatedConfigKernel plan

        validateRetained frame validated = do
            requireCondition "authenticated handoff binding" (signed == retained)
            requireCondition "token commitment" (not (Text.null (handoffTokenCommitment signed)))
            requireText "requested project verb" (projectVerbName ProjectUp) (handoffVerb signed)
            requireText "cursor project verb" (projectVerbName ProjectUp) (projectVerbName (lifecycleCursorVerb cursor))
            requireText "journal project verb" (projectVerbName ProjectUp) (acquisitionJournalRootVerb journal)
            requireText "verified lifecycle phase" (lifecyclePhaseName Execute) (lifecyclePhaseName (verifiedConfigHandoffPhase handoff))
            requireText "retained lifecycle phase" (lifecyclePhaseName Execute) (lifecyclePhaseName retainedPhase)
            requireText "signed lifecycle phase" (lifecyclePhaseName Execute) (handoffPhase signed)
            requireText "cursor lifecycle phase" (lifecyclePhaseName Execute) (lifecyclePhaseName (lifecycleCursorPhase cursor))
            requireText "plan specification digest" (handoffSpecDigest signed) canonicalSpecDigest
            requireText "validated specification digest" canonicalSpecDigest (validatedConfigSpecDigest retainedConfig)
            requireText "plan configuration digest" (handoffChildConfigDigest signed) canonicalConfigDigest
            requireText "validated configuration digest" canonicalConfigDigest (validatedConfigDigest retainedConfig)
            requireText "stable plan digest" (handoffPlanRevision signed) canonicalPlanDigest
            requireText "digest binding" canonicalPlanDigest (planDigestBindingDigestKernel digestBinding)
            requireText "acquisition snapshot digest" canonicalPlanDigest (acquisitionJournalSnapshotDigest journal)
            requireText "plan project" signedProject (projectPlanProfileProjectNameKernel plan)
            requireText "plan protected store" signedStore (projectPlanProfileStoreIdentityKernel plan)
            requireWord "plan broker epoch" signedGeneration (projectPlanProfileEpochKernel plan)
            requireWord "acquisition broker epoch" signedGeneration (acquisitionJournalBrokerGeneration journal)
            expectedScope <- childStableScope signed
            requireText "plan lifecycle scope" expectedScope (projectPlanProfileNameKernel plan)
            requireText "acquisition stable scope" expectedScope (acquisitionJournalStableScope journal)
            let frameId = projectFrameId frame
                context = validatedContextValue validated
            requireText "authenticated child frame" signedChild frameId
            requireCondition "project frame is outside the admitted topology" (topologyContainsFrame (topology plan) frameId)
            requireMaybeText "authenticated parent frame" (handoffParentFrame signed) (topologyParentFrame (topology plan) frameId)
            requireText "cursor frame" frameId (lifecycleCursorFrame cursor)
            requireText "validated context current frame" frameId (Context.currentFrame context)
            placement <-
                either
                    (const (malformed "validated context has no structural placement"))
                    Right
                    (Context.contextPlacement context)
            requireCondition
                "validated context placement refuses cluster lifecycle commands"
                ( Context.placementAllowsCommand
                    placement
                    (Context.isRootFrame context)
                    Context.ClusterLifecycleCommand
                )

        childStableScope binding
            | handoffScope binding == "Production" = Right "production"
            | Just runName <- Text.stripPrefix "Harness " (handoffScope binding)
            , not (Text.null runName) = Right ("harness:" <> runName)
            | otherwise = malformed "authenticated handoff carries an unknown lifecycle scope"

        contextAuthorityFailure failure =
            AuthorityMalformedBinding (Text.pack (lifecycleContextErrorMessage failure))
        malformed = Left . AuthorityMalformedBinding
        requireCondition subject condition
            | condition = Right ()
            | otherwise = malformed (subject <> " does not match")
        requireText subject expected observed =
            requireCondition subject (expected == observed)
        requireMaybeText subject expected observed =
            requireCondition subject (observed == Just expected)
        requireWord subject expected observed =
            requireCondition subject (expected == observed)

-- | Descriptive frame text for the hidden shared entry sum.
authorizedChildCursorFrameNameKernel ::
    AuthorizedChildCursor
        scope specDigest planDigest brokerGeneration parentFrame
        planId configId childFrame VerbUp ExecutePhase ->
    Text.Text
authorizedChildCursorFrameNameKernel (AuthorizedExecuteChildCursor _ authority) =
    commandAuthorityFrame authority

-- | Descriptive closed verb for the hidden shared entry sum.
authorizedChildCursorVerbNameKernel ::
    AuthorizedChildCursor
        scope specDigest planDigest brokerGeneration parentFrame
        planId configId childFrame VerbUp ExecutePhase ->
    Text.Text
authorizedChildCursorVerbNameKernel (AuthorizedExecuteChildCursor _ authority) =
    projectVerbName (commandAuthorityVerb authority)

-- | Canonically render the exact opaque child-forward terminal identity.
renderForwardTerminalOriginKernel ::
    AuthorizedChildCursor
        scope specDigest planDigest brokerGeneration parentFrame
        planId configId childFrame VerbUp TeardownPhase ->
    ByteString.ByteString
renderForwardTerminalOriginKernel
    ( AuthorizedTeardownChildCursor
        ( AuthorizedExecuteChildCursor
            (AuthenticatedChildCursor handoff _ _ _ _ journal cursor)
            command
          )
        teardownCursor
      ) =
        LazyByteString.toStrict . Builder.toLazyByteString $
            foldMap frame
                [ "forward-terminal-origin-v1"
                , renderHandoffBinding (verifiedConfigHandoffBinding handoff)
                , text (invocationIdText (commandAuthorityInvocation command))
                , word (acquisitionJournalRecordVersion journal)
                , word (lifecycleCursorRecordVersion cursor)
                , word (lifecycleCursorRecordVersion teardownCursor)
                , text (projectVerbName ProjectUp)
                , text (lifecyclePhaseName Execute)
                , text (lifecyclePhaseName (lifecycleCursorPhase teardownCursor))
                ]
      where
        frame bytes =
            Builder.word64BE (fromIntegral (ByteString.length bytes))
                <> Builder.byteString bytes
        text = TextEncoding.encodeUtf8
        word = text . Text.pack . show

{- | Fixed interpreter for one exact child-origin Up/Execute entry.

The retained nested lifecycle context supplies the only store.  Success alone
advances the exact cursor to Teardown and then yields the opaque terminal origin
to the completion callback after unlock.  A refusal, exception, or Chain failure
leaves the consumed invocation durably fail-closed at Execute.  No retained
component is returned to the caller.
-}
runAuthorizedChildCursorKernel ::
    HostConfig ->
    SelfRef ->
    AuthorizedChildCursor
        scope specDigest planDigest brokerGeneration parentFrame
        planId configId childFrame VerbUp ExecutePhase ->
    ( AuthorizedChildCursor
        scope specDigest planDigest brokerGeneration parentFrame
        planId configId childFrame VerbUp TeardownPhase ->
      IO (Either String ())
    ) ->
    IO (Either String ())
runAuthorizedChildCursorKernel
    cfg
    self
    authorized@(
        AuthorizedExecuteChildCursor
            (AuthenticatedChildCursor _ _ plan _ lifecycleContext _ cursor)
            authority
      )
    complete =
        case
            withValidatedNestedLifecycleContext
                lifecycleContext
                (\_root store _current _frame _validated -> run store)
        of
            Left failure -> pure (Left (lifecycleContextErrorMessage failure))
            Right interpreted -> interpreted
  where
    run store = do
        attempted <-
            try (runChainFromFrame cfg self store plan authority cursor) ::
                IO (Either SomeException (Either String ()))
        case attempted of
            Right (Left failure) -> pure (Left failure)
            Left exception ->
                pure $ case fromException exception of
                    Just (SafetyRefusal reason) ->
                        Left (safetyRefusalMarker ++ " " ++ reason)
                    Nothing -> Left (displayException exception)
            Right (Right ()) -> do
                transitioned <-
                    withTeardownLifecycleCursor cursor $ \teardownCursor ->
                        complete (AuthorizedTeardownChildCursor authorized teardownCursor)
                pure $ case transitioned of
                    Left failure -> Left (lifecycleErrorMessage failure)
                    Right outcome -> outcome

-- ---------------------------------------------------------------------------
-- Authenticated recovery child admission

{- | Seal one independently rebuilt local Down/Destroy child origin.

The received package is forced before any caller argument.  Its authenticated
coordinates select a fresh local plan from typed drafts, then the local
context and canonical adapter are checked before the existing-only recovery
cursor may advance.  The sole command reservation and sealed fixed-unit
callback occur only after all retained evidence is revalidated.
-}
withReceivedRecoveryChildOriginKernel ::
    forall scope brokerGeneration planDigest parentFrame signedChildFrame
        recoveryWireDigest recoveryWireId verb rootId specDigest configId cfg.
    (ProjectCfg cfg) =>
    ReceivedRecoveryDescent
        scope brokerGeneration planDigest parentFrame signedChildFrame
        recoveryWireDigest recoveryWireId verb ->
    ProtectedStore ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    NonEmpty (PlanDraft scope specDigest (cfg scope)) ->
    Context.BinaryContext ->
    ( forall localPlanId localFrame.
      ChildRecoveryOrigin scope specDigest planDigest brokerGeneration parentFrame
        localPlanId configId localFrame verb ->
      IO (Either Text.Text ())
    ) ->
    IO (Either Text.Text ())
{-# OPAQUE withReceivedRecoveryChildOriginKernel #-}
withReceivedRecoveryChildOriginKernel descent =
    case descent `seq` () of
        () -> \store root config drafts binaryContext use ->
            let validateEnvelope signed verb adapter projection grant = do
                        require "payload kind" (handoffPayloadKind signed == RecoveryAdapterWire)
                        requireText "scope" "Production" (handoffScope signed)
                        requireText "phase" "teardown" (handoffPhase signed)
                        case verb of
                            ProjectUp -> mismatch "verb" "down or destroy" "up"
                            ProjectDown -> requireText "verb" "down" (handoffVerb signed)
                            ProjectDestroy -> requireText "verb" "destroy" (handoffVerb signed)
                        require "token commitment" (not (Text.null (handoffTokenCommitment signed)))
                        require "adapter" (not (ByteString.null adapter))
                        require "projection" (not (ByteString.null projection))
                        require "grant" (not (ByteString.null grant))
                        requireText "adapter digest" (handoffChildConfigDigest signed) (recoveryWireDigest adapter)
                        require "adapter digest coordinate" $
                            Text.length (handoffChildConfigDigest signed) == 64
                                && Text.all lowerHex (handoffChildConfigDigest signed)
                        requireText "protected store" (handoffStoreIdentity signed)
                            (protectedStoreIdentityText (protectedStoreIdentity store))
                        requireText "specification digest" (handoffSpecDigest signed)
                            (validatedConfigSpecDigest config)

                lowerHex character =
                    ('0' <= character && character <= '9') || ('a' <= character && character <= 'f')
                require field condition
                    | condition = Right ()
                    | otherwise = mismatch field "exact" "different"
                requireText field expected observed
                    | expected == observed = Right ()
                    | otherwise = mismatch field expected observed
                requireWord field expected observed =
                    requireText field (Text.pack (show expected)) (Text.pack (show observed))
                mismatch field expected observed =
                    Left ("recovery child " <> field <> " mismatch: expected " <> expected <> ", observed " <> observed)
                failureText field failure =
                    "recovery child " <> field <> " refusal: " <> Text.pack (show failure)

                admitReceived edge _ verb adapter projection grant = do
                    let signed = verifiedHandoffBinding (receivedEdgeHandoff edge)
                    case validateEnvelope signed verb adapter projection grant of
                        Left failure -> pure (Left failure)
                        Right () -> case
                            withChildProjectPlanKernel
                                "production"
                                (handoffBrokerGeneration signed)
                                (handoffInstalledProject signed)
                                (handoffStoreIdentity signed)
                                (handoffPlanRevision signed)
                                config
                                drafts
                                (\plan digestBinding ->
                                    let snapshot = renderSnapshot plan
                                        planDigest = stablePlanSnapshotDigest snapshot
                                        validatePlanHere = do
                                            requireText "plan profile" "production" (projectPlanProfileNameKernel plan)
                                            requireText "plan project" (handoffInstalledProject signed) (projectPlanProfileProjectNameKernel plan)
                                            requireText "plan store" (handoffStoreIdentity signed) (projectPlanProfileStoreIdentityKernel plan)
                                            requireWord "plan broker generation" (handoffBrokerGeneration signed) (projectPlanProfileEpochKernel plan)
                                            requireText "plan specification digest" (handoffSpecDigest signed) (stablePlanSnapshotSpecDigest snapshot)
                                            requireText "plan configuration digest" (validatedConfigDigest config) (stablePlanSnapshotConfigDigest snapshot)
                                            requireText "stable plan digest" (handoffPlanRevision signed) planDigest
                                            requireText "plan digest binding" (handoffPlanRevision signed) (planDigestBindingDigestKernel digestBinding)
                                     in case validatePlanHere of
                                        Left failure -> pure (Left failure)
                                        Right () -> do
                                            admitted <-
                                                withValidatedLifecycleContext root store plan binaryContext $ \context ->
                                                    case
                                                        withValidatedNestedLifecycleContext context $
                                                            \_ contextStore current frame validated ->
                                                                let child = projectFrameId frame
                                                                    binary = validatedContextValue validated
                                                                    validateNestedHere = do
                                                                        require "context store" (protectedStoreIdentity contextStore == protectedStoreIdentity store)
                                                                        requireText "current frame" child (currentFrameId current)
                                                                        requireText "validated context frame" child (Context.currentFrame binary)
                                                                        requireText "signed child frame" (handoffChildFrame signed) child
                                                                        require "immediate topology edge" $
                                                                            [topologyEdge | topologyEdge@(_, edgeChild) <- topologyParentEdges (topology plan), edgeChild == child]
                                                                                == [(handoffParentFrame signed, child)]
                                                                        placement <-
                                                                            either (Left . failureText "context placement") Right
                                                                                (Context.contextPlacement binary)
                                                                        require "context placement" $
                                                                            Context.placementAllowsCommand placement (Context.isRootFrame binary)
                                                                                Context.ClusterLifecycleCommand
                                                                 in case validateNestedHere of
                                                                    Left failure -> pure (Left failure)
                                                                    Right () -> case
                                                                        withVerifiedReverseAdapterKernel plan current verb adapter (\teardown -> do
                                                                            opened <-
                                                                                reopenAuthenticatedRecoveryChildCursorKernel
                                                                                    acquisitionJournalAdmissionKernel
                                                                                    store
                                                                                    signed
                                                                                    plan
                                                                                    digestBinding
                                                                                    frame
                                                                                    verb
                                                                                    (\journal cursor ->
                                                                                        let validateRuntimeHere = do
                                                                                                validatePlanHere
                                                                                                validateNestedHere
                                                                                                requireText "teardown frame" child (teardownPlanFrameId teardown)
                                                                                                requireText "teardown verb" (projectVerbName verb) (teardownPlanVerbName teardown)
                                                                                                requireText "acquisition scope" "production" (acquisitionJournalStableScope journal)
                                                                                                requireText "acquisition plan digest" planDigest (acquisitionJournalSnapshotDigest journal)
                                                                                                requireWord "acquisition broker generation" (handoffBrokerGeneration signed) (acquisitionJournalBrokerGeneration journal)
                                                                                                requireWord "acquisition record version" (1 :: Word64) (acquisitionJournalRecordVersion journal)
                                                                                                withAcquisitionJournalPhase journal $ \phase ->
                                                                                                    requireText "acquisition seed" "prepare" (lifecyclePhaseName phase)
                                                                                                requireText "acquisition verb" (projectVerbName verb) (acquisitionJournalRootVerb journal)
                                                                                                requireText "cursor frame" child (lifecycleCursorFrame cursor)
                                                                                                requireText "cursor verb" (projectVerbName verb) (projectVerbName (lifecycleCursorVerb cursor))
                                                                                                requireText "cursor phase" "teardown" (lifecyclePhaseName (lifecycleCursorPhase cursor))
                                                                                                requireWord "cursor record version" (3 :: Word64) (lifecycleCursorRecordVersion cursor)
                                                                                                requireText "digest binding" planDigest (planDigestBindingDigestKernel digestBinding)
                                                                                         in case validateRuntimeHere of
                                                                                            Left failure -> pure (Left failure)
                                                                                            Right () -> do
                                                                                                reserved <-
                                                                                                    reserveCurrentLifecycleCommandKernel journal cursor $
                                                                                                        childCommandReservationKernel
                                                                                                            (handoffInstalledProject signed)
                                                                                                            (handoffStoreIdentity signed)
                                                                                                            (handoffBrokerGeneration signed)
                                                                                                            verb
                                                                                                            (handoffPlanRevision signed)
                                                                                                            Teardown
                                                                                                            (projectFrameId frame)
                                                                                                case reserved of
                                                                                                    Left failure ->
                                                                                                        pure (Left (authorityErrorMessage failure))
                                                                                                    Right authority ->
                                                                                                        let validateReservedHere = do
                                                                                                                require "command store" (commandAuthorityMatchesStore authority store)
                                                                                                                require "cursor command origin" (lifecycleCursorMatchesCommandAuthority authority cursor)
                                                                                                                requireText "command frame" child (commandAuthorityFrame authority)
                                                                                                                requireWord "command broker generation" (handoffBrokerGeneration signed) (brokerEpochWord (commandAuthorityEpoch authority))
                                                                                                                requireText "command verb" (projectVerbName verb) (projectVerbName (commandAuthorityVerb authority))
                                                                                                                requireText "command phase" "teardown" (lifecyclePhaseName (commandAuthorityPhase authority))
                                                                                                                require "command invocation" $
                                                                                                                    not (Text.null (invocationIdText (commandAuthorityInvocation authority)))
                                                                                                         in case validateReservedHere of
                                                                                                            Left failure -> pure (Left failure)
                                                                                                            Right () ->
                                                                                                                withChildRecoveryOriginKernel
                                                                                                                    descent
                                                                                                                    plan
                                                                                                                    digestBinding
                                                                                                                    context
                                                                                                                    teardown
                                                                                                                    journal
                                                                                                                    cursor
                                                                                                                    authority
                                                                                                                    use
                                                                                    )
                                                                            pure $
                                                                                either
                                                                                    (Left . Text.pack . lifecycleErrorMessage)
                                                                                    id
                                                                                    opened
                                                                        )
                                                                      of
                                                                        Left failure ->
                                                                            pure (Left (failureText "canonical reverse adapter" failure))
                                                                        Right action -> action
                                                    of
                                                        Left failure ->
                                                            pure (Left (failureText "nested context" failure))
                                                        Right action -> action
                                            pure $
                                                either
                                                    (Left . Text.pack . lifecycleContextErrorMessage)
                                                    id
                                                    admitted
                                )
                          of
                            Left failure -> pure (Left (failureText "local plan" failure))
                            Right action -> action
             in withReceivedRecoveryDescent descent admitReceived
