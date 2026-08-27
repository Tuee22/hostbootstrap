{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module ProjectPlanSpec (tests) where

import qualified Crypto.Hash as Hash
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (isSpace, ord)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, isPrefixOf, sort, stripPrefix)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Authority (
    AuthorityError (AuthorityMalformedBinding),
    InstalledProjectIdentity,
    ProjectVerb (ProjectUp),
    RootInvocationAuthority,
    VerbUp,
    brokerEpochWord,
    installedProjectName,
    rootAuthorityEpoch,
    rootScopeAuthority,
 )
import HostBootstrap.Config.Class (
    ProjectCfg (withProductionProjectCodec),
    ProjectCodec,
    projectCodecLabel,
    projectCodecSchemaText,
    projectCodecSpecDigest,
    renderProjectCodecValue,
 )
import HostBootstrap.Config.Fields (ScopeKind (ProductionScope))
import HostBootstrap.Config.Schema (
    ValidatedConfig,
    renderScopedProjectConfigBytes,
    validatedConfigDigest,
    validatedConfigSpecDigest,
    validatedConfigValue,
    withAuthenticatedConfigWire,
    withValidatedConfig,
    withVerifiedConfigHandoff,
 )
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Config.Vocab as V
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Handoff (
    HandoffBindingInput (..),
    HandoffPayloadKind (NarrowedProjectConfig),
    childConfigDigest,
    freshChallenge,
    grantHandoff,
    handoffOfferWire,
    mkHandoffOffer,
    productionHandoffScope,
    projectSigningKeyFromBytes,
    registerHandoffEdge,
    relayBinding,
    rootBrokerVerificationKey,
    verifiedConfigPayload,
    verifyHandoff,
    withRootBroker,
 )
import HostBootstrap.Lifecycle.Mode (
    LifecycleProfile,
    ModeError (ModeAuthorityFailure, ModeEvidenceMismatch, ModeSnapshotMismatch),
    RecoveredProductionLifecycleProfile,
    UnboundRunLease,
    VerifiedPlanSnapshot,
    planSnapshotCanonicalBytes,
    planSnapshotPlanDigest,
    planSnapshotSpecDigest,
    productionActiveMode,
    productionRootAuthority,
    productionRootModeLease,
    productionRootUnboundLease,
    recoveredProductionProfileCanonicalBytes,
    recoveredProductionProfileConfigDigest,
    recoveredProductionProfilePlanDigest,
    recoveredProductionProfileSpecDigest,
    unboundRunLeaseRunText,
    withProductionLifecycleProfile,
    withProductionRoot,
    withRecoveredProductionLifecycleProfile,
 )
import HostBootstrap.Lift (localContext)
import HostBootstrap.ProjectPlan (
    PlanDraft,
    PlanError (..),
    PlannedResourceKind (
        ClusterResourceKind,
        DockerResourceKind,
        DurableShareResourceKind,
        MinioResourceKind,
        ProviderResourceKind,
        RegistryResourceKind
    ),
    ProjectPlan,
    StablePlanSnapshot,
    chartWorkloadActivationFrame,
    chartWorkloadResourceFrame,
    chartWorkloadResourceKey,
    chartWorkloadReverseIdentity,
    forward,
    operationKeyText,
    planDraftsFromValidatedBuilder,
    plannedEdgeDependencyKey,
    plannedEdgeTargetKey,
    plannedResourceFrame,
    plannedResourceKey,
    plannedStepDependencyOperations,
    plannedStepFrameId,
    plannedStepOperationKey,
    plannedStepProjectedOperationKeys,
    renderSnapshot,
    stablePlanSnapshotBytes,
    stablePlanSnapshotConfigDigest,
    stablePlanSnapshotDigest,
    stablePlanSnapshotFormatVersion,
    stablePlanSnapshotRoot,
    stablePlanSnapshotSpecDigest,
    topology,
    topologyContainsFrame,
    topologyDescentEdges,
    topologyDescentFrom,
    topologyFrameLabel,
    topologyFrameOrder,
    topologyParentEdges,
    topologyParentFrame,
    withChartWorkloadResource,
    withPlannedEdge,
    withPlannedResourceOfKind,
    withPlannedStepGuestAliasProjection,
    withPlannedStepResourceOfKind,
    withProviderGuestAliasProjection,
 )
import HostBootstrap.ProjectPlan.Construct (
    FinalizedProjectSpec,
    childPlanAuthorityBinding,
    finalizedProjectCodec,
    finalizedProjectServices,
    projectPlanDrafts,
    projectPlanStepPlan,
    withChildProjectPlan,
    withFinalizedProjectSpec,
    withHarnessFinalizedProjectSpec,
    withProjectPlan,
    withRecoveredProductionProjectPlan,
    withRecoveredProductionProjectPlanInputs,
 )
import HostBootstrap.ProjectPlan.Snapshot (
    BoundPlanSnapshot,
    PlanDigestBinding,
    SnapshotError (SnapshotVerificationError),
    boundPlanSnapshotBytes,
    withBoundPlanSnapshot,
    withFreshBoundPlanSnapshot,
    withPersistedPlanSnapshot,
    withPlanDigestBinding,
 )
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    ProtectedRecord,
    ProtectedStore,
    RecordKey,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    openProtectedStore,
    readProtectedRecord,
    withProtectedEntry,
 )
import HostBootstrap.RoleLifecycle (DeclaredEffects (NoEffects))
import HostBootstrap.Service (
    ServiceRegistry,
    emptyServiceRegistry,
    finalizedServiceVariantNames,
    serviceDefinition,
    serviceId,
    serviceRoleSchemaFamilies,
    singletonServiceRegistry,
 )
import HostBootstrap.Step (
    CoreStepId (ContextInitId),
    ReversePolicy (PreserveOnReverse, ProjectManagedReverse),
    Step,
    StepFrame (StepFrame),
    StepIdentity (CoreStepIdentity),
    StepObservation (StepChanged, StepUnchanged),
    StepPlan,
    StepPlanError (..),
    contextInitStep,
    copySourceStep,
    declaresChartWorkloadResource,
    declaresProviderResource,
    declaresServiceActivation,
    deployChartStep,
    deployKindStep,
    deployVMStep,
    descendsVia,
    ensureStep,
    mkStepPlan,
    postHandoffStep,
    projectStep,
    projectStepId,
    projectsOperation,
    providerResourceAtCurrentFrame,
    providerResourceAtImmediateChild,
    stepPlanSteps,
 )
import qualified SourceGuard
import System.Directory (doesDirectoryExist, getCurrentDirectory, listDirectory)
import System.FilePath (
    takeExtension,
    (</>),
 )
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (
    assertBool,
    assertFailure,
    testCase,
    (@?=),
 )
import Unsafe.Coerce (unsafeCoerce)

tests :: TestTree
tests =
    testGroup
        "indexed project-plan foundation"
        [ testCase "Production and exact Harness runs jointly finalize one static project definition" $
            Fixture.withFixtureHarnessAuthority $ \(_project :: InstalledProjectIdentity projectId) authority ->
                withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \baseCodec ->
                    withFinalizedProjectSpec
                        ProductionScope
                        baseCodec
                        fixtureServiceRegistry
                        (\_ _ -> Right singletonPlan)
                        Fixture.refusingForwardChildPlan
                        ( \productionSpec ->
                            withSystemTempDirectory "hostbootstrap-finalized-project-spec" $ \directory -> do
                                productionDigest <-
                                    exerciseFinalizedSpec
                                        productionSpec
                                        directory
                                        ( Fixture.defaultProjectConfig
                                            "finalized-production"
                                            (Text.pack directory)
                                            Context.HostOrchestrator
                                        )
                                harnessDigest <-
                                    withHarnessFinalizedProjectSpec
                                        (V.harnessConfigAuthority authority)
                                        productionSpec
                                        ( \harnessSpec ->
                                            exerciseFinalizedSpec
                                                harnessSpec
                                                directory
                                                ( Fixture.defaultProjectConfig
                                                    "finalized-harness"
                                                    (Text.pack directory)
                                                    Context.TestHarness
                                                )
                                        )
                                assertBool
                                    "Production and Harness codec families receive distinct final specification digests"
                                    (productionDigest /= harnessDigest)
                        )
        , testCase "the draft builder receives the exact root and validated value" $
            withFoundation $ \_codec profile root config -> do
                let expectedRoot = canonicalProjectRootPath root
                    expectedConfig = validatedConfigValue config
                    build seenRoot seenConfig
                        | canonicalProjectRootPath seenRoot /= expectedRoot = Left EmptyStepPlan
                        | seenConfig /= expectedConfig = Left EmptyStepPlan
                        | otherwise = Right singletonPlan
                drafts <- expectRight (planDraftsFromValidatedBuilder root config build)
                expectPlanAccepted (withProjectPlan profile root config drafts (const ()))
        , testCase "fresh admission accepts the same authoritative graph deterministically" $
            withFoundation $ \_codec profile root config -> do
                drafts <- draftsFor root config singletonPlan
                expectPlanAccepted (withProjectPlan profile root config drafts (const ()))
                expectPlanAccepted (withProjectPlan profile root config drafts (const ()))
        , testCase "an authenticated config edge jointly admits the exact child plan and authority" $
            withSnapshotPlan singletonPlan $
                \store project rootAuthority _unbound spec root parentConfig _parentDrafts parentPlan -> do
                    let codec = finalizedProjectCodec spec
                        payload =
                            renderScopedProjectConfigBytes
                                codec
                                (validatedConfigValue parentConfig)
                        planDigest = stablePlanSnapshotDigest (renderSnapshot parentPlan)
                        input =
                            HandoffBindingInput
                                { requestedSpecDigest = validatedConfigSpecDigest parentConfig
                                , requestedPayloadKind = NarrowedProjectConfig
                                , requestedPlanRevision = planDigest
                                , requestedParentFrame = "parent-frame"
                                , requestedChildFrame = "host"
                                , requestedChildConfigDigest = childConfigDigest payload
                                , requestedPhase = "execute"
                                }
                    signingKey <-
                        expectRight
                            (projectSigningKeyFromBytes (ByteString.replicate 32 201))
                    brokered <-
                        withRootBroker
                            (productionHandoffScope project)
                            store
                            signingKey
                            rootAuthority
                            ( \broker -> do
                                (relay, token) <- expectRight =<< registerHandoffEdge broker input
                                offer <- expectRight (mkHandoffOffer relay payload token)
                                challenge <- freshChallenge
                                grant <- expectRight =<< grantHandoff broker offer challenge
                                handoff <-
                                    expectRight
                                        ( verifyHandoff
                                            (rootBrokerVerificationKey broker)
                                            (handoffOfferWire offer)
                                            (relayBinding relay)
                                            challenge
                                            grant
                                        )
                                authenticated <- expectRight (verifiedConfigPayload handoff)
                                configAdmission <-
                                    withAuthenticatedConfigWire codec authenticated $ \wire childConfig -> do
                                        childDrafts <- expectRight (projectPlanDrafts spec root childConfig)
                                        refined <-
                                            expectRight
                                                ( withVerifiedConfigHandoff
                                                    ProjectUp
                                                    handoff
                                                    wire
                                                    childConfig
                                                    ( \configHandoff ->
                                                        withChildProjectPlan
                                                            ProjectUp
                                                            configHandoff
                                                            wire
                                                            childConfig
                                                            childDrafts
                                                            ( \authority childPlan _digestBinding -> do
                                                                childPlanAuthorityBinding authority
                                                                    @?= relayBinding relay
                                                                stablePlanSnapshotDigest (renderSnapshot childPlan)
                                                                    @?= planDigest
                                                            )
                                                    )
                                                )
                                        expectRight refined
                                _ <- expectRight configAdmission
                                pure ()
                            )
                    _ <- expectRight brokered
                    pure ()
        , testCase "child admission refuses a signed revision other than the stable child plan digest" $
            withSnapshotPlan singletonPlan $
                \store project rootAuthority _unbound spec root parentConfig _parentDrafts parentPlan -> do
                    let codec = finalizedProjectCodec spec
                        payload =
                            renderScopedProjectConfigBytes
                                codec
                                (validatedConfigValue parentConfig)
                        childPlanDigest = stablePlanSnapshotDigest (renderSnapshot parentPlan)
                        signedRevision = "signed-but-not-the-child-plan"
                        input =
                            HandoffBindingInput
                                { requestedSpecDigest = validatedConfigSpecDigest parentConfig
                                , requestedPayloadKind = NarrowedProjectConfig
                                , requestedPlanRevision = signedRevision
                                , requestedParentFrame = "parent-frame"
                                , requestedChildFrame = "host"
                                , requestedChildConfigDigest = childConfigDigest payload
                                , requestedPhase = "execute"
                                }
                    assertBool
                        "the negative fixture uses a different signed revision"
                        (signedRevision /= childPlanDigest)
                    signingKey <-
                        expectRight
                            (projectSigningKeyFromBytes (ByteString.replicate 32 202))
                    brokered <-
                        withRootBroker
                            (productionHandoffScope project)
                            store
                            signingKey
                            rootAuthority
                            ( \broker -> do
                                (relay, token) <- expectRight =<< registerHandoffEdge broker input
                                offer <- expectRight (mkHandoffOffer relay payload token)
                                challenge <- freshChallenge
                                grant <- expectRight =<< grantHandoff broker offer challenge
                                handoff <-
                                    expectRight
                                        ( verifyHandoff
                                            (rootBrokerVerificationKey broker)
                                            (handoffOfferWire offer)
                                            (relayBinding relay)
                                            challenge
                                            grant
                                        )
                                authenticated <- expectRight (verifiedConfigPayload handoff)
                                configAdmission <-
                                    withAuthenticatedConfigWire codec authenticated $ \wire childConfig -> do
                                        childDrafts <- expectRight (projectPlanDrafts spec root childConfig)
                                        expectRight
                                            ( withVerifiedConfigHandoff
                                                ProjectUp
                                                handoff
                                                wire
                                                childConfig
                                                ( \configHandoff ->
                                                    withChildProjectPlan
                                                        ProjectUp
                                                        configHandoff
                                                        wire
                                                        childConfig
                                                        childDrafts
                                                        (\_authority _childPlan _digestBinding -> ())
                                                )
                                            )
                                refused <- expectRight configAdmission
                                case refused of
                                    Left (AuthorityMalformedBinding detail) ->
                                        assertBool
                                            "the refusal identifies the stable plan digest"
                                            ("stable plan digest" `Text.isInfixOf` detail)
                                    other ->
                                        assertFailure
                                            ( "expected a signed-revision child-plan refusal, got "
                                                <> show other
                                            )
                            )
                    _ <- expectRight brokered
                    pure ()
        , testCase "admission rejects drafts stamped by another canonical root" $
            withFoundation $ \_codec profile root config -> do
                drafts <- draftsFor root config singletonPlan
                withSystemTempDirectory "hostbootstrap-project-plan-other-root" $ \otherRootPath -> do
                    rooted <-
                        withCanonicalProjectRoot
                            (otherRootPath </> "fixture.dhall")
                            otherRootPath
                            ( \otherRoot ->
                                pure
                                    ( canonicalProjectRootPath otherRoot
                                    , withProjectPlan
                                        profile
                                        otherRoot
                                        config
                                        drafts
                                        (const ())
                                    )
                            )
                    (expectedRoot, outcome) <- either (fail . show) pure rooted
                    case outcome of
                        Left (PlanDraftRootMismatch expected observed) -> do
                            expected @?= expectedRoot
                            observed @?= canonicalProjectRootPath root
                        other -> assertFailure ("expected a root mismatch, got " <> show other)
        , testCase "admission rejects drafts from another validated config identity" $
            withFoundation $ \codec profile root config -> do
                drafts <- draftsFor root config singletonPlan
                let replacement =
                        Fixture.defaultProjectConfig
                            "different-project"
                            "/different-root"
                            Context.HostOrchestrator
                validated <-
                    withValidatedConfig codec replacement $ \_wire otherConfig ->
                        pure (withProjectPlan profile root otherConfig drafts (const ()))
                outcome <- either fail pure validated
                case outcome of
                    Left (PlanDraftConfigurationMismatch _ _) -> pure ()
                    other -> assertFailure ("expected a config mismatch, got " <> show other)
        , testCase "admission revalidates duplicate node and resource identities" $
            withFoundation $ \_codec profile root config -> do
                drafts <- draftsFor root config singletonPlan
                let outcome = withProjectPlan profile root config (drafts <> drafts) (const ())
                outcome
                    @?= Left
                        ( InvalidProjectPlan
                            (DuplicateStepIdentities [CoreStepIdentity ContextInitId])
                        )
        , testCase "admission rejects a frame whose parent has no descent" $
            withFoundation $ \_codec profile root config -> do
                hostDrafts <- draftsFor root config singletonPlan
                guestDrafts <- draftsFor root config guestOnlyPlan
                withProjectPlan profile root config (hostDrafts <> guestDrafts) (const ())
                    @?= Left (InvalidProjectPlan (MissingFrameDescent "host"))
        , testCase "admission rejects conflicting declarations for one frame identity" $
            withFoundation $ \_codec profile root config -> do
                hostDrafts <- draftsFor root config singletonPlan
                relabelledDrafts <- draftsFor root config relabelledHostPlan
                withProjectPlan profile root config (hostDrafts <> relabelledDrafts) (const ())
                    @?= Left
                        ( InvalidProjectPlan
                            (ConflictingFrameLabels "host" ["Host", "Relabelled host"])
                        )
        , testCase "admission rejects normal work placed after a handoff suffix" $
            withFoundation $ \_codec profile root config -> do
                handoffDrafts <- draftsFor root config hostWithPostHandoffPlan
                guestDrafts <- draftsFor root config guestOnlyPlan
                withProjectPlan profile root config (handoffDrafts <> guestDrafts) (const ())
                    @?= Left (InvalidProjectPlan (PostHandoffBeforeDescentComplete 3))
        , testCase "forward is non-empty and preserves exact admitted dependency order" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config topologyFixturePlan $ \plan -> do
                    let projected = forward plan
                        nodes = NonEmpty.toList projected
                    NonEmpty.length projected @?= 2
                    map (Text.pack . operationKeyText . plannedStepOperationKey) nodes
                        @?= ["core:context-init", "core:ensure-ghc"]
                    map plannedStepFrameId nodes @?= ["host", "guest"]
                    map
                        ( map
                            (\(operation, frame) -> (Text.pack (operationKeyText operation), frame))
                            . plannedStepDependencyOperations
                        )
                        nodes
                        @?= [[], [("core:context-init", "host")]]
        , testCase "the closed resource relation projects all six admitted families" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config closedResourceFamilyPlan $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [providerNode, shareNode, dockerNode, minioNode, registryNode, clusterNode] ->
                            sequence
                                [ withPlannedResourceOfKind
                                    plan
                                    ProviderResourceKind
                                    (plannedStepOperationKey providerNode)
                                    plannedResourceKey
                                , withPlannedResourceOfKind
                                    plan
                                    DurableShareResourceKind
                                    (plannedStepOperationKey shareNode)
                                    plannedResourceKey
                                , withPlannedResourceOfKind
                                    plan
                                    DockerResourceKind
                                    (plannedStepOperationKey dockerNode)
                                    plannedResourceKey
                                , withPlannedResourceOfKind
                                    plan
                                    MinioResourceKind
                                    (plannedStepOperationKey minioNode)
                                    plannedResourceKey
                                , withPlannedResourceOfKind
                                    plan
                                    RegistryResourceKind
                                    (plannedStepOperationKey registryNode)
                                    plannedResourceKey
                                , withPlannedResourceOfKind
                                    plan
                                    ClusterResourceKind
                                    (plannedStepOperationKey clusterNode)
                                    plannedResourceKey
                                ]
                                @?= Right
                                    [ "core:deploy-vm"
                                    , "core:copy-source"
                                    , "core:ensure-docker"
                                    , "project:deploy-minio"
                                    , "project:deploy-registry"
                                    , "core:deploy-kind"
                                    ]
                        other -> assertFailure ("expected six resource nodes, got " <> show (length other))
        , testCase "provider declarations derive current and immediate-child frames from their authoring operations" $
            withFoundation $ \_codec profile root config -> do
                let direct =
                        either (error . show) id $
                            mkStepPlan
                                [ descendsVia localContext $
                                    declaresProviderResource providerResourceAtCurrentFrame $
                                        projectStep (either error id (projectStepId "direct-provider")) ProjectManagedReverse "reserve direct provider" (StepFrame "host" "Host") (const (pure StepChanged))
                                , ensureStep "guest" "guest" (StepFrame "guest" "Guest") (const (pure StepChanged))
                                ]
                    vm =
                        either (error . show) id $
                            mkStepPlan
                                [ descendsVia localContext $
                                    declaresProviderResource providerResourceAtImmediateChild $
                                        deployVMStep "reserve VM provider" (StepFrame "host" "Host") (const (pure StepChanged))
                                , ensureStep "guest" "guest" (StepFrame "guest" "Guest") (const (pure StepChanged))
                                ]
                withAdmittedProjectPlan profile root config direct $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        node : _ ->
                            withPlannedResourceOfKind plan ProviderResourceKind (plannedStepOperationKey node) plannedResourceFrame
                                @?= Right "host"
                        [] -> assertFailure "the direct provider plan was empty"
                withAdmittedProjectPlan profile root config vm $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        node : _ ->
                            withPlannedResourceOfKind plan ProviderResourceKind (plannedStepOperationKey node) plannedResourceFrame
                                @?= Right "guest"
                        [] -> assertFailure "the VM provider plan was empty"
        , testCase "chart workload resources project their exact admitted identity and bind stable bytes" $
            withFoundation $ \_codec profile root config -> do
                withAdmittedProjectPlan profile root config (chartWorkloadPlan "sha256:workload-a") $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [_clusterNode, chartNode] ->
                            expectRight
                                ( withChartWorkloadResource plan (plannedStepOperationKey chartNode) $ \resource ->
                                    ( chartWorkloadResourceKey resource
                                    , chartWorkloadResourceFrame resource
                                    , chartWorkloadActivationFrame resource
                                    , chartWorkloadReverseIdentity resource
                                    )
                                )
                                >>= ( @?=
                                        ( "core:deploy-chart"
                                        , "cluster"
                                        , "service"
                                        , ("demo", "demo-system", "workload/demo")
                                        )
                                    )
                        other -> assertFailure ("expected cluster and chart nodes, got " <> show (length other))
                first <- snapshotFor profile root config (chartWorkloadPlan "sha256:workload-a")
                second <- snapshotFor profile root config (chartWorkloadPlan "sha256:workload-b")
                assertBool "the workload declaration digest must affect canonical bytes" (stablePlanSnapshotBytes first /= stablePlanSnapshotBytes second)
                firstFrame <- snapshotFor profile root config (chartWorkloadPlanAt "service-a" "sha256:workload-a")
                secondFrame <- snapshotFor profile root config (chartWorkloadPlanAt "service-b" "sha256:workload-a")
                assertBool "the activation frame must affect canonical bytes" (stablePlanSnapshotBytes firstFrame /= stablePlanSnapshotBytes secondFrame)
        , testCase "chart workload declarations require one exact same-frame cluster parent" $
            withFoundation $ \_codec profile root config -> do
                drafts <- draftsFor root config chartWorkloadWithoutClusterPlan
                withProjectPlan profile root config drafts (const ())
                    @?= Left
                        (PlanResourceBindingMismatch "chart cluster parent" "one same-frame cluster dependency" "none")
        , testCase "service activation placements are exact canonical plan declarations" $
            withFoundation $ \_codec profile root config -> do
                first <- snapshotFor profile root config (serviceActivationPlan "daemon-a" "accelerator" ["network-listen", "process-spawn"])
                second <- snapshotFor profile root config (serviceActivationPlan "daemon-b" "accelerator" ["network-listen", "process-spawn"])
                third <- snapshotFor profile root config (serviceActivationPlan "daemon-a" "accelerator" ["network-listen"])
                assertBool "the activation frame must affect canonical bytes" (stablePlanSnapshotBytes first /= stablePlanSnapshotBytes second)
                assertBool "the permitted effects must affect canonical bytes" (stablePlanSnapshotBytes first /= stablePlanSnapshotBytes third)
        , testCase "service activation frames are unique across chart and standalone declarations" $
            withFoundation $ \_codec profile root config -> do
                drafts <- draftsFor root config collidingServiceActivationPlan
                withProjectPlan profile root config drafts (const ())
                    @?= Left
                        (PlanResourceBindingMismatch "service activation frame" "unique" "duplicate")
        , testCase "resource projection refuses wrong kinds, absent keys, and reversed edges" $
            withFoundation $ \_codec profile root config -> do
                providerKey <-
                    withAdmittedProjectPlan profile root config resourceProjectionPlan $ \plan ->
                        pure (plannedStepOperationKey (NonEmpty.head (forward plan)))
                withAdmittedProjectPlan profile root config singletonPlan $ \plan ->
                    withPlannedResourceOfKind
                        plan
                        ProviderResourceKind
                        providerKey
                        (const ())
                        @?= Left (PlanResourceOperationMissing "core:deploy-vm")
                withAdmittedProjectPlan profile root config resourceProjectionPlan $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [providerNode, shareNode, _clusterNode] -> do
                            withPlannedResourceOfKind
                                plan
                                ClusterResourceKind
                                (plannedStepOperationKey providerNode)
                                (const ())
                                @?= Left (PlanResourceKindMismatch "core:deploy-vm" "cluster")
                            let reversedEdge =
                                    joinPlan $
                                        withPlannedResourceOfKind
                                            plan
                                            ProviderResourceKind
                                            (plannedStepOperationKey providerNode)
                                            ( \provider ->
                                                joinPlan $
                                                    withPlannedResourceOfKind
                                                        plan
                                                        DurableShareResourceKind
                                                        (plannedStepOperationKey shareNode)
                                                        ( \share ->
                                                            withPlannedEdge plan provider share (const ())
                                                        )
                                            )
                            reversedEdge
                                @?= Left
                                    ( PlanDependencyEdgeMissing
                                        "core:deploy-vm"
                                        "core:copy-source"
                                    )
                        other -> assertFailure ("expected three projected nodes, got " <> show (length other))
        , testCase "closed resource families and edges project only from the exact plan" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config resourceProjectionPlan $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [providerNode, shareNode, _clusterNode] -> do
                            let projected =
                                    joinPlan $
                                        withPlannedResourceOfKind
                                            plan
                                            ProviderResourceKind
                                            (plannedStepOperationKey providerNode)
                                            ( \provider ->
                                                joinPlan $
                                                    withPlannedResourceOfKind
                                                        plan
                                                        DurableShareResourceKind
                                                        (plannedStepOperationKey shareNode)
                                                        ( \share ->
                                                            withPlannedEdge plan share provider $ \edge ->
                                                                ( plannedResourceKey provider
                                                                , plannedResourceFrame provider
                                                                , plannedResourceKey share
                                                                , plannedResourceFrame share
                                                                , plannedEdgeTargetKey edge
                                                                , plannedEdgeDependencyKey edge
                                                                )
                                                        )
                                            )
                            projected
                                @?= Right
                                    ( "core:deploy-vm"
                                    , "host"
                                    , "core:copy-source"
                                    , "provider"
                                    , "core:copy-source"
                                    , "core:deploy-vm"
                                    )
                        other -> assertFailure ("expected three projected nodes, got " <> show (length other))
        , testCase "a PlannedStep reaches only its own resource and dependency prefix" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config resourceProjectionPlan $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [providerNode, shareNode, clusterNode] -> do
                            let localAlias =
                                    joinPlan $
                                        withPlannedStepResourceOfKind
                                            shareNode
                                            ProviderResourceKind
                                            (plannedStepOperationKey providerNode)
                                            ( \provider ->
                                                joinPlan $
                                                    withPlannedStepResourceOfKind
                                                        shareNode
                                                        DurableShareResourceKind
                                                        (plannedStepOperationKey shareNode)
                                                        ( \share ->
                                                            withPlannedStepGuestAliasProjection
                                                                shareNode
                                                                provider
                                                                share
                                                                (\alias edge -> (plannedResourceKey alias, plannedEdgeDependencyKey edge))
                                                        )
                                            )
                                laterResource =
                                    withPlannedStepResourceOfKind
                                        shareNode
                                        ClusterResourceKind
                                        (plannedStepOperationKey clusterNode)
                                        (const ())
                            localAlias
                                @?= Right
                                    ( "core:deploy-vm/core:copy-source/guest-alias"
                                    , "core:copy-source"
                                    )
                            laterResource
                                @?= Left (PlanNodeResourceOutsidePrefix "core:deploy-kind")
                        other -> assertFailure ("expected three projected nodes, got " <> show (length other))
        , testCase "provider guest alias projection requires the share node declaration" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config unprojectedResourcePlan $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [providerNode, shareNode, _clusterNode] -> do
                            let projected =
                                    joinPlan $
                                        withPlannedResourceOfKind
                                            plan
                                            ProviderResourceKind
                                            (plannedStepOperationKey providerNode)
                                            ( \provider ->
                                                joinPlan $
                                                    withPlannedResourceOfKind
                                                        plan
                                                        DurableShareResourceKind
                                                        (plannedStepOperationKey shareNode)
                                                        ( \share ->
                                                            withProviderGuestAliasProjection
                                                                plan
                                                                provider
                                                                share
                                                                (\_ _ -> ())
                                                        )
                                            )
                            projected
                                @?= Left
                                    ( PlanProjectedOperationMissing
                                        "core:deploy-vm/core:copy-source/guest-alias"
                                    )
                        other -> assertFailure ("expected three projected nodes, got " <> show (length other))
        , testCase "topology retains ordered membership and matching parent/descent edges" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config topologyFixturePlan $ \plan -> do
                    let derived = topology plan
                    topologyFrameOrder derived
                        @?= NonEmpty.fromList
                            [("host", "Host"), ("guest", "Guest")]
                    topologyParentEdges derived @?= [("host", "guest")]
                    topologyDescentEdges derived
                        @?= [("host", "guest", localContext)]
                    topologyContainsFrame derived "host" @?= True
                    topologyContainsFrame derived "absent" @?= False
                    topologyFrameLabel derived "guest" @?= Just "Guest"
                    topologyParentFrame derived "host" @?= Nothing
                    topologyParentFrame derived "guest" @?= Just "host"
                    topologyDescentFrom derived "host"
                        @?= Just ("guest", localContext)
                    topologyDescentFrom derived "guest" @?= Nothing
        , testCase "renderSnapshot is deterministic across fresh local plan identities" $
            withFoundation $ \_codec profile root config -> do
                first <- snapshotFor profile root config topologyFixturePlan
                second <- snapshotFor profile root config topologyFixturePlan
                first @?= second
        , testCase "stable snapshot accessors expose exact admitted identities and derived digest" $
            withFoundation $ \_codec profile root config -> do
                snapshot <- snapshotFor profile root config topologyFixturePlan
                stablePlanSnapshotFormatVersion snapshot @?= 7
                stablePlanSnapshotRoot snapshot
                    @?= canonicalProjectRootPath root
                stablePlanSnapshotSpecDigest snapshot
                    @?= validatedConfigSpecDigest config
                stablePlanSnapshotConfigDigest snapshot
                    @?= validatedConfigDigest config
                stablePlanSnapshotDigest snapshot
                    @?= ( validatedConfigSpecDigest config
                            <> ":"
                            <> sha256Text (stablePlanSnapshotBytes snapshot)
                        )
        , testCase "coordinated canonical-root and draft substitution changes the stable snapshot" $
            withFoundation $ \_codec profile root config -> do
                original <- snapshotFor profile root config singletonPlan
                withSystemTempDirectory "hostbootstrap-project-plan-other-canonical-root" $ \directory -> do
                    rooted <-
                        withCanonicalProjectRoot
                            (directory </> "fixture.dhall")
                            directory
                            ( \otherRoot -> do
                                substituted <- snapshotFor profile otherRoot config singletonPlan
                                stablePlanSnapshotRoot substituted
                                    @?= canonicalProjectRootPath otherRoot
                                assertBool
                                    "a coordinated root-and-draft substitution retained canonical bytes"
                                    ( stablePlanSnapshotBytes original
                                        /= stablePlanSnapshotBytes substituted
                                    )
                                assertBool
                                    "a coordinated root-and-draft substitution retained the stable digest"
                                    ( stablePlanSnapshotDigest original
                                        /= stablePlanSnapshotDigest substituted
                                    )
                            )
                    either (fail . show) pure rooted
        , testCase "canonical bytes carry the header, version, and explicit collection counts" $
            withFoundation $ \_codec profile root config -> do
                snapshot <- snapshotFor profile root config projectedOperationPlan
                let bytes = stablePlanSnapshotBytes snapshot
                ByteString.take 18 bytes @?= ByteStringChar8.pack "HOSTBOOTSTRAP-PLAN"
                ByteString.take 8 (ByteString.drop 18 bytes)
                    @?= encodedWord64 7
                assertBool
                    "the step collection lacked its explicit count"
                    (framedCount "steps" 1 `ByteString.isInfixOf` bytes)
                assertBool
                    "the projected-operation collection lacked its explicit count"
                    (framedCount "projected-operations" 1 `ByteString.isInfixOf` bytes)
        , testCase "projected stable operation keys are snapshot material" $
            withFoundation $ \_codec profile root config -> do
                ordinary <- snapshotFor profile root config singletonPlan
                projected <- snapshotFor profile root config projectedOperationPlan
                assertBool
                    "a projected operation did not change canonical bytes"
                    ( stablePlanSnapshotBytes ordinary
                        /= stablePlanSnapshotBytes projected
                    )
                assertBool
                    "a projected operation did not change the stable digest"
                    ( stablePlanSnapshotDigest ordinary
                        /= stablePlanSnapshotDigest projected
                    )
                withAdmittedProjectPlan profile root config projectedOperationPlan $ \plan ->
                    map
                        (map (Text.pack . operationKeyText) . plannedStepProjectedOperationKeys)
                        (NonEmpty.toList (forward plan))
                        @?= [["core:context-init/relation"]]
        , testCase "executable callbacks are absent from stable snapshot bytes" $
            withFoundation $ \_codec profile root config -> do
                changed <- snapshotFor profile root config singletonPlan
                unchanged <- snapshotFor profile root config callbackReplacementPlan
                stablePlanSnapshotBytes changed
                    @?= stablePlanSnapshotBytes unchanged
                stablePlanSnapshotDigest changed
                    @?= stablePlanSnapshotDigest unchanged
        , testCase "length framing separates delimiter-shaped labels" $
            withFoundation $ \_codec profile root config -> do
                first <- snapshotFor profile root config framedLabelPlanA
                second <- snapshotFor profile root config framedLabelPlanB
                assertBool
                    "distinct length-framed labels collapsed"
                    (stablePlanSnapshotBytes first /= stablePlanSnapshotBytes second)
        , testCase "fixed admitted input has golden canonical bytes under its exact root" $
            withFoundation $ \codec profile root _config -> do
                let fixedValue =
                        Fixture.defaultProjectConfig
                            "golden-project"
                            "/golden-root"
                            Context.HostOrchestrator
                admitted <-
                    withValidatedConfig codec fixedValue $ \_wire fixedConfig -> do
                        snapshot <- snapshotFor profile root fixedConfig projectedOperationPlan
                        hexBytes (stablePlanSnapshotBytes snapshot)
                            @?= goldenSnapshotBytesHex (canonicalProjectRootPath root)
                either fail pure admitted
        , testCase "verified exact snapshot mints a same-spec local plan-digest binding" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    (stablePlanSnapshotSpecDigest stable)
                    (stablePlanSnapshotDigest stable)
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable)
                bound <-
                    withPlanDigestBinding unbound plan $ \verified _binding ->
                        pure
                            ( planSnapshotSpecDigest verified
                            , planSnapshotPlanDigest verified
                            )
                bound
                    @?= Right
                        ( stablePlanSnapshotSpecDigest stable
                        , stablePlanSnapshotDigest stable
                        )
        , testCase "a locally bound snapshot preserves the verified canonical bytes" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    (stablePlanSnapshotSpecDigest stable)
                    (stablePlanSnapshotDigest stable)
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable)
                produced <-
                    withFreshBoundPlanSnapshot unbound plan $ \verified bound _binding ->
                        pure
                            ( planSnapshotCanonicalBytes verified
                            , boundPlanSnapshotBytes bound
                            )
                produced
                    @?= Right
                        ( Just (stablePlanSnapshotBytes stable)
                        , stablePlanSnapshotBytes stable
                        )
        , testCase "a verified snapshot and its local bound evidence are produced as one indexed triple" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    (stablePlanSnapshotSpecDigest stable)
                    (stablePlanSnapshotDigest stable)
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable)
                produced <-
                    withFreshBoundPlanSnapshot unbound plan pairedSnapshotEvidence
                produced
                    @?= Right
                        ( stablePlanSnapshotSpecDigest stable
                        , stablePlanSnapshotDigest stable
                        , stablePlanSnapshotBytes stable
                        )
        , testCase "binding rejects a verified snapshot with another specification digest" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    "other-specification"
                    (stablePlanSnapshotDigest stable)
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable)
                bound <- withPlanDigestBinding unbound plan (\_ _ -> pure ())
                bound
                    @?= Left
                        ( SnapshotVerificationError
                            ( ModeSnapshotMismatch
                                (stablePlanSnapshotSpecDigest stable)
                                "other-specification"
                            )
                        )
        , testCase "binding rejects a verified snapshot with another configuration digest" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    (stablePlanSnapshotSpecDigest stable)
                    (stablePlanSnapshotDigest stable)
                    "other-configuration"
                    (stablePlanSnapshotBytes stable)
                bound <- withPlanDigestBinding unbound plan (\_ _ -> pure ())
                bound
                    @?= Left
                        ( SnapshotVerificationError
                            ( ModeSnapshotMismatch
                                (stablePlanSnapshotConfigDigest stable)
                                "other-configuration"
                            )
                        )
        , testCase "binding rejects different canonical bytes under matching digest terms" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    (stablePlanSnapshotSpecDigest stable)
                    (stablePlanSnapshotDigest stable)
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable <> ByteString.singleton 0)
                bound <- withPlanDigestBinding unbound plan (\_ _ -> pure ())
                bound
                    @?= Left
                        ( SnapshotVerificationError
                            ( ModeSnapshotMismatch
                                "the indexed plan's exact canonical bytes"
                                "different canonical bytes"
                            )
                        )
        , testCase "binding rejects another stable plan digest under matching canonical bytes" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    (stablePlanSnapshotSpecDigest stable)
                    "other-plan-digest"
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable)
                bound <- withPlanDigestBinding unbound plan (\_ _ -> pure ())
                bound
                    @?= Left
                        ( SnapshotVerificationError
                            ( ModeSnapshotMismatch
                                (stablePlanSnapshotDigest stable)
                                "other-plan-digest"
                            )
                        )
        , testCase "plan admission rejects the same project and epoch from another protected store before writing" $
            withSnapshotPlan singletonPlan $ \_storeA project rootA _unboundA _spec _canonicalRoot _config _drafts plan ->
                withSystemTempDirectory "hostbootstrap-plan-origin-store-b" $ \directory -> do
                    storeB <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
                    continued <- newIORef (0 :: Int)
                    second <-
                        withProductionRoot storeB project ProjectUp $ \productionRoot -> do
                            let unboundB = productionRootUnboundLease productionRoot
                                epochA = brokerEpochWord (rootAuthorityEpoch rootA)
                                epochB =
                                    brokerEpochWord
                                        (rootAuthorityEpoch (productionRootAuthority productionRoot))
                            epochB @?= epochA
                            outcome <-
                                withPersistedPlanSnapshot
                                    (productionRootAuthority productionRoot)
                                    unboundB
                                    plan
                                    (\_ _ _ _ _ -> modifyIORef' continued (+ 1))
                            pure (Right (outcome, unboundRunLeaseRunText unboundB))
                    (outcome, runName) <- either (fail . show) pure second
                    case outcome of
                        Left
                            ( SnapshotVerificationError
                                    (ModeEvidenceMismatch "plan store" expected observed)
                                ) -> assertBool "store identities differ" (expected /= observed)
                        other -> assertFailure ("expected plan-store refusal, observed " <> show other)
                    key <-
                        either
                            (fail . show)
                            pure
                            (mkRecordKey ("snapshot." <> installedProjectName project <> "." <> runName))
                    observed <-
                        withProtectedEntry storeB $ \session ->
                            readProtectedRecord session key
                    either (fail . show) pure observed >>= (@?= Nothing)
                    readIORef continued >>= (@?= 0)
        , testGroup
            "exact recovered Production project plan"
            recoveredProductionProjectPlanCases
        , sourceBoundaryTests
        ]

recoveredProductionProjectPlanCases :: [TestTree]
recoveredProductionProjectPlanCases =
    [ testCase "exact reconstruction retains one admitted plan identity and is pure" $
        withRecoveredProjectPlanFixture $ \store _project inputs -> do
            before <- readAllProtectedRecords store
            let first = recoverProjectPlan inputs recoveredSnapshot
                second = recoverProjectPlan inputs recoveredSnapshot
            case (inputs, first) of
                ( RecoveredProjectPlanInputs profile root _verified _bound _binding _config _drafts
                    , Right snapshot
                    ) -> do
                        stablePlanSnapshotRoot snapshot
                            @?= canonicalProjectRootPath root
                        stablePlanSnapshotSpecDigest snapshot
                            @?= recoveredProductionProfileSpecDigest profile
                        stablePlanSnapshotConfigDigest snapshot
                            @?= recoveredProductionProfileConfigDigest profile
                        stablePlanSnapshotBytes snapshot
                            @?= recoveredProductionProfileCanonicalBytes profile
                        stablePlanSnapshotDigest snapshot
                            @?= recoveredProductionProfilePlanDigest profile
                (_, other) -> assertFailure ("expected exact recovered plan, observed " <> show other)
            second @?= first
            readAllProtectedRecords store >>= (@?= before)
    , testCase "the recovered inputs yield the exact specification at the recovered index" $
        withRecoveredProjectPlanCandidateFixture
            singletonPlan
            fixtureServiceRegistry
            ( \store _project profile root _verified _bound _binding candidateSpec candidateConfig -> do
                before <- readAllProtectedRecords store
                let candidateCodec = finalizedProjectCodec candidateSpec
                    candidateServices = finalizedProjectServices candidateSpec
                    observed =
                        withRecoveredProductionProjectPlanInputs
                            profile
                            root
                            candidateSpec
                            candidateConfig
                            ( \recoveredSpec recoveredConfig recoveredDrafts ->
                                let recoveredCodec = finalizedProjectCodec recoveredSpec
                                    recoveredServices = finalizedProjectServices recoveredSpec
                                 in ( projectCodecSpecDigest recoveredCodec
                                    , projectCodecLabel recoveredCodec
                                    , projectCodecSchemaText recoveredCodec
                                    , finalizedServiceVariantNames recoveredServices
                                    , serviceRoleSchemaFamilies recoveredServices
                                    , renderProjectCodecValue
                                        recoveredCodec
                                        (validatedConfigValue recoveredConfig)
                                    , NonEmpty.length recoveredDrafts
                                    , fmap
                                        NonEmpty.length
                                        (projectPlanDrafts recoveredSpec root recoveredConfig)
                                    , validatedConfigSpecDigest recoveredConfig
                                    )
                            )
                case observed of
                    Left failure ->
                        assertFailure ("recovered inputs refused: " <> show failure)
                    Right
                        ( specDigest
                            , label
                            , schema
                            , variants
                            , families
                            , rendered
                            , draftCount
                            , rebuiltDraftCount
                            , configSpecDigest
                            ) -> do
                            -- the reindexed specification is at the recovered
                            -- profile's index, and its digest is unchanged
                            specDigest @?= recoveredProductionProfileSpecDigest profile
                            specDigest @?= projectCodecSpecDigest candidateCodec
                            configSpecDigest @?= specDigest
                            -- every retained codec and registry term survives
                            label @?= projectCodecLabel candidateCodec
                            schema @?= projectCodecSchemaText candidateCodec
                            variants @?= finalizedServiceVariantNames candidateServices
                            families @?= serviceRoleSchemaFamilies candidateServices
                            rendered
                                @?= renderProjectCodecValue
                                    candidateCodec
                                    (validatedConfigValue candidateConfig)
                            -- the retained plan builder is preserved and still
                            -- produces the same stream at the recovered index
                            draftCount @?= 1
                            rebuiltDraftCount @?= Right draftCount
                readAllProtectedRecords store >>= (@?= before)
            )
    , testCase "an empty service registry still proves its digest before the specification is reindexed" $
        withRecoveredProjectPlanCandidateFixtureUsing
            emptyServiceRegistry
            singletonPlan
            emptyServiceRegistry
            ( \store _project profile root _verified _bound _binding candidateSpec candidateConfig -> do
                before <- readAllProtectedRecords store
                let observed =
                        withRecoveredProductionProjectPlanInputs
                            profile
                            root
                            candidateSpec
                            candidateConfig
                            ( \recoveredSpec _recoveredConfig _recoveredDrafts ->
                                ( projectCodecSpecDigest (finalizedProjectCodec recoveredSpec)
                                , finalizedServiceVariantNames
                                    (finalizedProjectServices recoveredSpec)
                                )
                            )
                case observed of
                    Left failure ->
                        assertFailure ("recovered inputs refused: " <> show failure)
                    Right (specDigest, variants) -> do
                        specDigest @?= recoveredProductionProfileSpecDigest profile
                        variants @?= []
                readAllProtectedRecords store >>= (@?= before)
            )
    , testCase "a different independently finalized specification is refused before refinement" $
        withRecoveredProjectPlanCandidateFixture
            singletonPlan
            alternateFixtureServiceRegistry
            ( \store _project profile root _verified _bound _binding candidateSpec candidateConfig -> do
                before <- readAllProtectedRecords store
                assertRecoveryMismatch
                    "finalized specification"
                    ( withRecoveredProductionProjectPlanInputs
                        profile
                        root
                        candidateSpec
                        candidateConfig
                        (\_spec _refined _drafts -> error "recovered-input callback entered")
                    )
                readAllProtectedRecords store >>= (@?= before)
            )
    , testCase "different independently validated config bytes are refused before refinement" $
        withRecoveredProjectPlanCandidateFixture
            singletonPlan
            fixtureServiceRegistry
            ( \store project profile root _verified _bound _binding candidateSpec _candidateConfig -> do
                before <- readAllProtectedRecords store
                let driftedValue =
                        Fixture.defaultProjectConfig
                            (installedProjectName project <> "-drift")
                            (Text.pack (canonicalProjectRootPath root))
                            Context.HostOrchestrator
                validated <-
                    withValidatedConfig
                        (finalizedProjectCodec candidateSpec)
                        driftedValue
                        ( \_wire driftedConfig ->
                            assertRecoveryMismatch
                                "validated configuration digest"
                                ( withRecoveredProductionProjectPlanInputs
                                    profile
                                    root
                                    candidateSpec
                                    driftedConfig
                                    (\_spec _refined _drafts -> error "recovered-input callback entered")
                                )
                        )
                either fail pure validated
                readAllProtectedRecords store >>= (@?= before)
            )
    , testCase "same-spec candidate builder drift is regenerated then refused by canonical bytes" $
        withRecoveredProjectPlanCandidateFixture
            projectedOperationPlan
            fixtureServiceRegistry
            ( \_store _project profile root verified bound binding candidateSpec candidateConfig ->
                assertRecoveryMismatch
                    "candidate canonical bytes"
                    ( withRecoveredProductionProjectPlanInputs
                        profile
                        root
                        candidateSpec
                        candidateConfig
                        ( \_recoveredSpec recoveredConfig recoveredDrafts ->
                            withRecoveredProductionProjectPlan
                                profile
                                root
                                verified
                                bound
                                binding
                                recoveredConfig
                                recoveredDrafts
                                (const (error "recovered-plan callback entered"))
                        )
                        >>= id
                    )
            )
    , testCase "coordinated canonical-root and draft drift is refused" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            case inputs of
                RecoveredProjectPlanInputs profile _root verified bound binding config _drafts ->
                    withSystemTempDirectory "hostbootstrap-recovered-plan-root-drift" $ \directory -> do
                        rooted <-
                            withCanonicalProjectRoot
                                (directory </> "fixture.dhall")
                                directory
                                ( \otherRoot -> do
                                    otherDrafts <- draftsFor otherRoot config singletonPlan
                                    pure
                                        ( withRecoveredProductionProjectPlan
                                            profile
                                            otherRoot
                                            verified
                                            bound
                                            binding
                                            config
                                            otherDrafts
                                            (const (error "recovered-plan callback entered"))
                                        )
                                )
                        either (fail . show) pure rooted
                            >>= assertRecoveryMismatch "candidate canonical bytes"
    , testCase "configuration drift is refused before candidate admission" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            withRecoveredProjectPlanFixture $ \_foreignStore _foreignProject foreignInputs ->
                case (inputs, foreignInputs) of
                    ( RecoveredProjectPlanInputs profile root verified bound binding _config _drafts
                        , RecoveredProjectPlanInputs _foreignProfile _foreignRoot _foreignVerified _foreignBound _foreignBinding foreignConfig _foreignDrafts
                        ) -> do
                            -- The coercion deliberately models independently decoded opaque
                            -- evidence at a compromised package boundary. Public callers cannot
                            -- erase these nominal indices; the compile-fail suite proves that.
                            let driftedConfig = unsafeCoerce foreignConfig
                            driftedDrafts <- draftsFor root driftedConfig singletonPlan
                            assertRecoveryMismatch
                                "validated configuration digest"
                                ( withRecoveredProductionProjectPlan
                                    profile
                                    root
                                    verified
                                    bound
                                    binding
                                    driftedConfig
                                    driftedDrafts
                                    (const (error "recovered-plan callback entered"))
                                )
    , testCase "draft graph drift is refused by exact canonical bytes" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            case inputs of
                RecoveredProjectPlanInputs profile root verified bound binding config _drafts -> do
                    driftedDrafts <- draftsFor root config projectedOperationPlan
                    assertRecoveryMismatch
                        "candidate canonical bytes"
                        ( withRecoveredProductionProjectPlan
                            profile
                            root
                            verified
                            bound
                            binding
                            config
                            driftedDrafts
                            (const (error "recovered-plan callback entered"))
                        )
    , testCase "verified-snapshot origin drift is refused" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            withRecoveredProjectPlanFixture $ \_foreignStore _foreignProject foreignInputs ->
                case (inputs, foreignInputs) of
                    ( RecoveredProjectPlanInputs profile root _verified bound binding config drafts
                        , RecoveredProjectPlanInputs _foreignProfile _foreignRoot foreignVerified _foreignBound _foreignBinding _foreignConfig _foreignDrafts
                        ) ->
                            assertRecoveryMismatch
                                "verified snapshot store"
                                ( withRecoveredProductionProjectPlan
                                    profile
                                    root
                                    (unsafeCoerce foreignVerified)
                                    bound
                                    binding
                                    config
                                    drafts
                                    (const (error "recovered-plan callback entered"))
                                )
    , testCase "bound-snapshot byte drift is refused" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            withRecoveredProjectPlanFixture $ \_foreignStore _foreignProject foreignInputs ->
                case (inputs, foreignInputs) of
                    ( RecoveredProjectPlanInputs profile root verified _bound binding config drafts
                        , RecoveredProjectPlanInputs _foreignProfile _foreignRoot _foreignVerified foreignBound _foreignBinding _foreignConfig _foreignDrafts
                        ) ->
                            assertRecoveryMismatch
                                "bound snapshot canonical bytes"
                                ( withRecoveredProductionProjectPlan
                                    profile
                                    root
                                    verified
                                    (unsafeCoerce foreignBound)
                                    binding
                                    config
                                    drafts
                                    (const (error "recovered-plan callback entered"))
                                )
    , testCase "plan-digest binding drift is refused" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            withRecoveredProjectPlanFixture $ \_foreignStore _foreignProject foreignInputs ->
                case (inputs, foreignInputs) of
                    ( RecoveredProjectPlanInputs profile root verified bound _binding config drafts
                        , RecoveredProjectPlanInputs _foreignProfile _foreignRoot _foreignVerified _foreignBound foreignBinding _foreignConfig _foreignDrafts
                        ) ->
                            assertRecoveryMismatch
                                "plan digest binding"
                                ( withRecoveredProductionProjectPlan
                                    profile
                                    root
                                    verified
                                    bound
                                    (unsafeCoerce foreignBinding)
                                    config
                                    drafts
                                    (const (error "recovered-plan callback entered"))
                                )
    , testCase "recovered-profile origin drift is refused" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            withRecoveredProjectPlanFixture $ \_foreignStore _foreignProject foreignInputs ->
                case (inputs, foreignInputs) of
                    ( RecoveredProjectPlanInputs _profile root verified bound binding config drafts
                        , RecoveredProjectPlanInputs foreignProfile _foreignRoot _foreignVerified _foreignBound _foreignBinding _foreignConfig _foreignDrafts
                        ) ->
                            assertRecoveryMismatch
                                "verified snapshot store"
                                ( withRecoveredProductionProjectPlan
                                    (unsafeCoerce foreignProfile)
                                    root
                                    verified
                                    bound
                                    binding
                                    config
                                    drafts
                                    (const (error "recovered-plan callback entered"))
                                )
    ]

sourceBoundaryTests :: TestTree
sourceBoundaryTests =
    testGroup
        "public and representation boundaries"
        [ testCase "Cabal exposes the facade and evidence leaves but hides both construction kernels" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                librarySource <-
                    maybe
                        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                        pure
                        (mainLibraryStanza cabalSource)
                let exposed = fieldModules "exposed-modules:" librarySource
                    privateModules = fieldModules "other-modules:" librarySource
                    allExposed = fieldModules "exposed-modules:" cabalSource
                    requiredPublic =
                        [ "HostBootstrap.ProjectPlan"
                        , "HostBootstrap.ProjectPlan.Construct"
                        , "HostBootstrap.ProjectPlan.Frame"
                        , "HostBootstrap.ProjectPlan.Snapshot"
                        , "HostBootstrap.Authority.ProjectPlan"
                        ]
                assertRequiredMembers "main-library exposed modules" requiredPublic exposed
                assertBool
                    "HostBootstrap.Lifecycle.Plan is not a main-library other-module"
                    ("HostBootstrap.Lifecycle.Plan" `elem` privateModules)
                assertBool
                    "HostBootstrap.Lifecycle.Plan is exposed by a Cabal component"
                    ("HostBootstrap.Lifecycle.Plan" `notElem` allExposed)
                length
                    (filter (== "HostBootstrap.ProjectPlan.Construct.Internal") privateModules)
                    @?= 1
                assertBool
                    "the finalized-spec owner is exposed by a Cabal component"
                    ("HostBootstrap.ProjectPlan.Construct.Internal" `notElem` allExposed)
                fieldModules
                    "exposed-modules:"
                    "library\n  exposed-modules: HostBootstrap.Lifecycle.Plan\n"
                    @?= ["HostBootstrap.Lifecycle.Plan"]
        , testCase "exactly the audited production modules import the plan kernel" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                sources <- readProductionSources sourceRoot
                let importerSources =
                        [ (moduleName, source)
                        | (moduleName, _path, source) <- sources
                        , SourceGuard.importsModule "HostBootstrap.Lifecycle.Plan" source
                        ]
                    importers =
                        sort
                            (map fst importerSources)
                    allowed =
                        sort
                            [ "HostBootstrap.ProjectPlan"
                            , "HostBootstrap.ProjectPlan.Construct"
                            , "HostBootstrap.ProjectPlan.Frame"
                            , "HostBootstrap.ProjectPlan.Handoff.Internal"
                            , "HostBootstrap.ProjectPlan.Projection.Internal"
                            , "HostBootstrap.ProjectPlan.Child.Internal"
                            , "HostBootstrap.ProjectPlan.Snapshot"
                            , "HostBootstrap.Authority.ProjectPlan"
                            , "HostBootstrap.Authority.ProjectPlan.Internal"
                            , "HostBootstrap.Cluster.Workload.Binding"
                            , "HostBootstrap.Cluster.Workload"
                            , "HostBootstrap.Command.Child"
                            , "HostBootstrap.Command.LifecycleEntry"
                            , "HostBootstrap.Lifecycle.Context"
                            , "HostBootstrap.Lifecycle.Mode"
                            , "HostBootstrap.Lifecycle.Recovery"
                            , "HostBootstrap.Lifecycle.RootedPlan"
                            , "HostBootstrap.Lifecycle.Session"
                            , "HostBootstrap.Reconcile"
                            , "HostBootstrap.Teardown.Internal"
                            ]
                importers @?= allowed
                mapM_
                    ( \(moduleName, source) ->
                        if moduleName
                            `elem` [ "HostBootstrap.ProjectPlan.Child.Internal"
                                   , "HostBootstrap.Command.LifecycleEntry"
                                   ]
                            then do
                                assertBool
                                    (moduleName <> " owns its fixed Chain interpreter")
                                    (SourceGuard.importsModule "HostBootstrap.Chain" source)
                                assertBool
                                    (moduleName <> " owns its fixed SelfRef interpreter input")
                                    (SourceGuard.importsModule "HostBootstrap.Lift" source)
                            else
                                assertBool
                                    (moduleName <> " imports the effectful HostBootstrap.Lift module")
                                    (not (SourceGuard.importsModule "HostBootstrap.Lift" source))
                    )
                    importerSources
                let fixedRunnerCallers =
                        sort
                            [ moduleName
                            | (moduleName, _path, source) <- sources
                            , moduleName /= "HostBootstrap.ProjectPlan.Child.Internal"
                            , SourceGuard.countHaskellIdentifier "runAuthorizedChildCursorKernel" source > 0
                            ]
                fixedRunnerCallers @?= ["HostBootstrap.Command.LifecycleEntry"]
        , testCase "the plan foundation depends only on the pure lift-context vocabulary" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                let foundationalPaths =
                        [ ("Step", sourceRoot </> "HostBootstrap" </> "Step.hs")
                        , ("ProjectPlan", sourceRoot </> "HostBootstrap" </> "ProjectPlan.hs")
                        ,
                            ( "Lifecycle.Plan"
                            , sourceRoot
                                </> "HostBootstrap"
                                </> "Lifecycle"
                                </> "Plan.hs"
                            )
                        ]
                foundationalSources <-
                    traverse
                        ( \(label, path) -> do
                            source <- readFile path
                            pure (label, source)
                        )
                        foundationalPaths
                mapM_
                    ( \(label, source) -> do
                        assertBool
                            (label <> " does not import HostBootstrap.Lift.Context")
                            (SourceGuard.importsModule "HostBootstrap.Lift.Context" source)
                        assertBool
                            (label <> " imports the effectful HostBootstrap.Lift module")
                            (not (SourceGuard.importsModule "HostBootstrap.Lift" source))
                        mapM_
                            ( \providerModule ->
                                assertBool
                                    (label <> " imports provider realization " <> providerModule)
                                    (not (SourceGuard.importsModule providerModule source))
                            )
                            [ "HostBootstrap.Incus"
                            , "HostBootstrap.Lima"
                            , "HostBootstrap.Wsl2"
                            ]
                    )
                    foundationalSources
                chainSource <- readFile (sourceRoot </> "HostBootstrap" </> "Chain.hs")
                assertBool
                    "Chain does not import the effectful HostBootstrap.Lift module"
                    (SourceGuard.importsModule "HostBootstrap.Lift" chainSource)
        , testCase "static and finalized project specifications retain their exact indices" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                cliSource <- readFile (sourceRoot </> "HostBootstrap" </> "CLI.hs")
                constructSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Construct.hs")
                internalSource <-
                    readFile
                        ( sourceRoot
                            </> "HostBootstrap"
                            </> "ProjectPlan"
                            </> "Construct"
                            </> "Internal.hs"
                        )
                let cli = normalizeWhitespace cliSource
                    construct = normalizeWhitespace constructSource
                    internal = normalizeWhitespace internalSource
                assertContains
                    "the static ProjectSpec authoring-family header"
                    "data ProjectSpec cfg tcfg = ProjectSpec"
                    cli
                assertContains
                    "the finalized scope/specification header"
                    "data FinalizedProjectSpec scope specDigest cfg = FinalizedProjectSpec"
                    internal
                assertContains
                    "the finalized specification's nominal roles"
                    "type role FinalizedProjectSpec nominal nominal nominal"
                    internal
                assertAbsent
                    "the public construction facade does not own the finalized representation"
                    "data FinalizedProjectSpec"
                    construct
        , testCase "forward-child projection ownership is hidden, fixed-unit, acyclic, and frozen" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                let cliPath = sourceRoot </> "HostBootstrap" </> "CLI.hs"
                    constructPath =
                        sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Construct.hs"
                    internalPath =
                        sourceRoot
                            </> "HostBootstrap"
                            </> "ProjectPlan"
                            </> "Construct"
                            </> "Internal.hs"
                cliBytes <- ByteString.readFile cliPath
                constructBytes <- ByteString.readFile constructPath
                internalBytes <- ByteString.readFile internalPath
                let cliSource = Text.unpack (TextEncoding.decodeUtf8 cliBytes)
                    constructSource = Text.unpack (TextEncoding.decodeUtf8 constructBytes)
                    internalSource = Text.unpack (TextEncoding.decodeUtf8 internalBytes)
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources sourceRoot
                librarySource <-
                    maybe
                        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                        pure
                        (mainLibraryStanza cabalSource)
                constructExports <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan.Construct"
                        constructSource
                internalExports <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan.Construct.Internal"
                        internalSource
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                partsSource <-
                    requiredSourceSection
                        "the legacy finalized-spec parts fold"
                        "withFinalizedProjectSpecPartsKernel ::"
                        "finalizedProjectCodecKernel ::"
                        internalSource
                let kernelSource =
                        unlines
                            ( dropWhile
                                (not . isPrefixOf "withFinalizedForwardChildProjectionKernel ::")
                                (lines internalSource)
                            )
                    cli = normalizeWhitespace cliSource
                    internal = normalizeWhitespace internalSource
                    kernel = normalizeWhitespace kernelSource
                    exposed = fieldModules "exposed-modules:" librarySource
                    privateModules = fieldModules "other-modules:" librarySource
                    users identifier =
                        sort
                            [ moduleName
                            | (moduleName, _path, source) <- sources
                            , SourceGuard.countHaskellIdentifier identifier source > 0
                            ]
                    importers moduleName =
                        sort
                            [ importer
                            | (importer, _path, source) <- sources
                            , SourceGuard.importsModule moduleName source
                            ]
                    sprintOwners =
                        sort
                            [ moduleName
                            | (moduleName, _path, source) <- sources
                            , any
                                (\identifier -> SourceGuard.countHaskellIdentifier identifier source > 0)
                                [ "addForwardChildPlan"
                                , "withFinalizedProjectSpecKernel"
                                , "withFinalizedForwardChildProjectionKernel"
                                ]
                            ]
                    forbiddenPrefixes =
                        [ "HostBootstrap.CLI"
                        , "HostBootstrap.ProjectPlan"
                        , "HostBootstrap.Lifecycle.Plan"
                        , "HostBootstrap.Chain"
                        , "HostBootstrap.Command"
                        , "HostBootstrap.Handoff"
                        ]
                    forbiddenImports =
                        [ (prefix, imported)
                        | imported <- SourceGuard.haskellImports internalSource
                        , prefix <- forbiddenPrefixes
                        , imported == prefix || (prefix <> ".") `isPrefixOf` imported
                        ]
                    declarationName sourceLine =
                        case words (dropWhile isSpace sourceLine) of
                            "data" : name : _ -> [name]
                            "newtype" : name : _ -> [name]
                            "type" : "role" : _ -> []
                            "type" : name : _ -> [name]
                            _ -> []
                    namedDeclarations =
                        sort
                            ( concatMap
                                declarationName
                                ( lines cliSource
                                    <> lines constructSource
                                    <> lines internalSource
                                )
                            )
                    cliSignificant = significantHaskellLineCount cliSource
                    constructSignificant = significantHaskellLineCount constructSource
                    internalSignificant = significantHaskellLineCount internalSource
                    -- The two shared owners also carry the later digest-proven
                    -- specification reindex join, whose 46 lines belong to its
                    -- own sprint rather than to this projector attribution, and
                    -- the frame-child classification `runCLI` consults before
                    -- the parser, whose 5 lines belong to its own sprint too.
                    -- The identity-install boundary contributes ten later CLI
                    -- lines: the original lifecycle preflight plus Phase 24's
                    -- exact private post-copy entry and installer. Phase 16's
                    -- private relay classifier contributes three later lines to
                    -- shared CLI and is excluded from this projector owner's
                    -- attribution just like the five frame-child lines. The
                    -- read-only shipped cluster-exposure dispatcher contributes
                    -- eight more later CLI lines.
                    frozenBaseline = 394 + 618 + 46 + 5 + 10 + 3 + 8
                    sourceAttribution =
                        cliSignificant
                            + constructSignificant
                            + internalSignificant
                            - frozenBaseline
                    cabalAttribution =
                        length
                            ( filter
                                (== "HostBootstrap.ProjectPlan.Construct.Internal")
                                privateModules
                            )
                assertBool
                    "the hidden projector kernel source marker is missing"
                    (not (null kernelSource))
                filter (/= ",") internalExports
                    @?= [ "FinalizedProjectSpec"
                        , "finalizedProjectCodecKernel"
                        , "finalizedProjectServicesKernel"
                        , "withFinalizedProjectSpecKernel"
                        , "withHarnessFinalizedProjectSpecKernel"
                        , "withFinalizedProjectSpecPartsKernel"
                        , "withFinalizedForwardChildProjectionKernel"
                        , "reindexFinalizedProjectSpecKernel"
                        ]
                assertBool
                    "the public facade no longer exports FinalizedProjectSpec abstractly"
                    ("FinalizedProjectSpec" `elem` constructExports)
                assertBool
                    "the public facade exports the FinalizedProjectSpec constructor"
                    (not (containsTokenSequence ["FinalizedProjectSpec", "("] constructExports))
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "withFinalizedForwardChildProjectionKernel"
                    , "finalizedForwardChildProjector"
                    ]
                length
                    (filter (== "HostBootstrap.ProjectPlan.Construct.Internal") privateModules)
                    @?= 1
                assertBool
                    "the hidden finalized-spec owner appears in exposed-modules"
                    ("HostBootstrap.ProjectPlan.Construct.Internal" `notElem` exposed)
                importers "HostBootstrap.ProjectPlan.Construct.Internal"
                    @?= [ "HostBootstrap.Lifecycle.RootedPlan"
                        , "HostBootstrap.ProjectPlan.Construct"
                        , "HostBootstrap.ProjectPlan.Handoff.Internal"
                        , "HostBootstrap.ProjectPlan.Projection.Internal"
                        ]
                users "withFinalizedForwardChildProjectionKernel"
                    @?= [ "HostBootstrap.ProjectPlan.Construct.Internal"
                        , "HostBootstrap.ProjectPlan.Projection.Internal"
                        ]
                users "addForwardChildPlan" @?= ["HostBootstrap.CLI"]
                sprintOwners
                    @?= [ "HostBootstrap.CLI"
                        , "HostBootstrap.ProjectPlan.Construct"
                        , "HostBootstrap.ProjectPlan.Construct.Internal"
                        , "HostBootstrap.ProjectPlan.Projection.Internal"
                        ]
                forbiddenImports @?= []
                namedDeclarations
                    @?= sort
                        [ "FinalizedProjectSpec"
                        , "ProjectSpec"
                        , "ProjectSpecBuilder"
                        , "ProjectSpecError"
                        , "StepFragment"
                        ]
                mapM_
                    (\(label, fragment, body) -> assertContains label fragment body)
                    [
                        ( "ProjectSpec retains one scope-polymorphic pure projector"
                        , "psForwardChildPlan :: forall scope. cfg scope -> Text -> Text -> LiftContext -> Either String (FilePath, cfg scope, StepPlan)"
                        , cli
                        )
                    ,
                        ( "ProjectSpecBuilder retains the same scope-polymorphic pure projector"
                        , "pbForwardChildPlan :: forall scope. cfg scope -> Text -> Text -> LiftContext -> Either String (FilePath, cfg scope, StepPlan)"
                        , cli
                        )
                    ,
                        ( "the public installer accepts exactly the fixed projector shape"
                        , "addForwardChildPlan :: ( forall scope. cfg scope -> Text -> Text -> LiftContext -> Either String (FilePath, cfg scope, StepPlan) ) -> ProjectSpecBuilder cfg tcfg -> ProjectSpecBuilder cfg tcfg"
                        , cli
                        )
                    ,
                        ( "the hidden kernel consumes the exact parent config and has a fixed refusal callback"
                        , "withFinalizedForwardChildProjectionKernel :: FinalizedProjectSpec scope specDigest cfg -> ValidatedConfig scope specDigest parentConfigId (cfg scope) -> Text -> Text -> LiftContext -> ( forall childConfigId. FilePath -> ValidatedConfig scope specDigest childConfigId (cfg scope) -> StepPlan -> IO (Either Text ()) ) -> IO (Either Text ())"
                        , kernel
                        )
                    ]
                assertFragmentsInOrder
                    "real-project construction starts refusing, installs once, and saturates duplicates"
                    [ "pbForwardChildPlan = refuseForwardChildPlan"
                    , "pbForwardChildPlanCount = 0"
                    , "addForwardChildPlan projector builder ="
                    , "pbForwardChildPlan = projector"
                    , "pbForwardChildPlanCount = case pbForwardChildPlanCount builder of"
                    , "0 -> 1"
                    , "_ -> 2"
                    , "psForwardChildPlan = pbForwardChildPlan builder"
                    , "pbForwardChildPlanCount builder == 0 = Left MissingForwardChildPlan"
                    , "pbForwardChildPlanCount builder /= 1 = Left DuplicateForwardChildPlan"
                    ]
                    cli
                assertContains
                    "the real CLI retains the exact installed projector during finalization"
                    "(psStepPlan spec) (psForwardChildPlan spec)"
                    cli
                assertContains
                    "the bare CLI supplies its owned cluster gate and default child refusal"
                    "(bareStepPlan progName) refuseForwardChildPlan"
                    cli
                assertFragmentsInOrder
                    "the exact retained projector precedes canonical child-config validation and fixed callback flattening"
                    [ "case projector"
                    , "validatedConfigValue parentConfig"
                    , "parentFrame"
                    , "childFrame"
                    , "liftContext of"
                    , "Left failure ->"
                    , "Text.pack failure"
                    , "Right (path, childConfig, plan) ->"
                    , "withValidatedConfig codec childConfig"
                    , "\\_wire exactConfig -> use path exactConfig plan"
                    , "case validated of"
                    , "Left failure ->"
                    , "Text.pack failure"
                    , "Right (Left failure) -> failure `seq` pure (Left failure)"
                    , "Right (Right ()) -> pure (Right ())"
                    ]
                    kernel
                assertFragmentsInOrder
                    "Harness refinalization reuses the exact static projector"
                    [ "scopeKind baseCodec staticServices staticPlanBuilder staticProjector use ="
                    , "FinalizedProjectSpec finalCodec finalServices staticPlanBuilder staticProjector staticServices staticPlanBuilder staticProjector"
                    , "FinalizedProjectSpec _ _ _ _ staticServices staticPlanBuilder staticProjector"
                    , "withFinalizedProjectSpecKernel HarnessScope baseCodec staticServices staticPlanBuilder staticProjector use"
                    ]
                    internal
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier kernelSource @?= 0)
                    [ "ByteString"
                    , "CanonicalProjectRoot"
                    , "PlanDraft"
                    , "ProjectPlan"
                    , "VerifiedConfigWire"
                    , "internalFinalizedProjectPlanBuilder"
                    , "internalStaticProjectPlanBuilder"
                    , "renderScopedProjectConfigBytes"
                    , "topology"
                    ]
                SourceGuard.countHaskellIdentifier "withValidatedConfig" kernelSource @?= 1
                SourceGuard.countHaskellIdentifier "validatedConfigValue" kernelSource @?= 1
                SourceGuard.countHaskellIdentifier "projector" kernelSource @?= 2
                SourceGuard.countHaskellIdentifier "staticProjector" internalSource @?= 7
                SourceGuard.countHaskellIdentifier "addForwardChildPlan" cliSource @?= 3
                SourceGuard.countHaskellIdentifier "pbForwardChildPlanCount" cliSource @?= 6
                SourceGuard.countHaskellIdentifier "refuseForwardChildPlan" cliSource @?= 4
                SourceGuard.countHaskellIdentifier "psForwardChildPlan" cliSource @?= 3
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier partsSource @?= 0)
                    [ "FilePath"
                    , "LiftContext"
                    , "projector"
                    , "withFinalizedForwardChildProjectionKernel"
                    ]
                sha256Text constructBytes
                    @?= "fab624d2ddf1fd067b57323d23df1c7a9c4d2e0b6e78fbbd1a6638e704017eb4"
                sha256Text internalBytes
                    @?= "fc8731711546662895f1766e7e79968c9fc30bd770a0f159915fd981a4ee185d"
                (constructSignificant, internalSignificant) @?= (591, 220)
                assertBool "shared CLI lost the installed projector surface" (cliSignificant >= 424)
                (sourceAttribution, sourceAttribution + cabalAttribution)
                    @?= (172, 173)
                assertBool
                    "the accepted soft-target underrun crossed the hard 400-line split boundary"
                    (sourceAttribution + cabalAttribution < 400)
        , testCase "planned-forward handoff is exact, inert, hidden, acyclic, and frozen" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                let handoffPath =
                        sourceRoot
                            </> "HostBootstrap"
                            </> "ProjectPlan"
                            </> "Handoff"
                            </> "Internal.hs"
                handoffBytes <- ByteString.readFile handoffPath
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                let handoffSource = Text.unpack (TextEncoding.decodeUtf8 handoffBytes)
                    handoff = normalizeWhitespace handoffSource
                sources <- readProductionSources sourceRoot
                librarySource <-
                    maybe
                        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                        pure
                        (mainLibraryStanza cabalSource)
                handoffExports <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan.Handoff.Internal"
                        handoffSource
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                let exposed = fieldModules "exposed-modules:" librarySource
                    allExposed = fieldModules "exposed-modules:" cabalSource
                    privateModules = fieldModules "other-modules:" librarySource
                    users identifier =
                        sort
                            [ moduleName
                            | (moduleName, _path, source) <- sources
                            , SourceGuard.countHaskellIdentifier identifier source > 0
                            ]
                    importers moduleName =
                        sort
                            [ importer
                            | (importer, _path, source) <- sources
                            , SourceGuard.importsModule moduleName source
                            ]
                    importedByHandoff = sort (SourceGuard.haskellImports handoffSource)
                filter (/= ",") handoffExports
                    @?= [ "PlannedForwardHandoff"
                        , "withPlannedForwardHandoffKernel"
                        , "withPlannedForwardProcessInputsKernel"
                        , "CatalogForwardHandoff"
                        , "withCatalogForwardHandoffKernel"
                        , "withCatalogForwardProcessInputsKernel"
                        ]
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "PlannedForwardHandoff"
                    , "withPlannedForwardHandoffKernel"
                    , "withPlannedForwardProcessInputsKernel"
                    , "CatalogForwardHandoff"
                    , "withCatalogForwardHandoffKernel"
                    , "withCatalogForwardProcessInputsKernel"
                    , "withProjectedProjectPlanKernel"
                    , "canonicalProjectedRootKernel"
                    ]
                length
                    (filter (== "HostBootstrap.ProjectPlan.Handoff.Internal") privateModules)
                    @?= 1
                assertBool
                    "the planned-forward package owner appears in the main exposed modules"
                    ("HostBootstrap.ProjectPlan.Handoff.Internal" `notElem` exposed)
                assertBool
                    "the planned-forward package owner is exposed by another Cabal component"
                    ("HostBootstrap.ProjectPlan.Handoff.Internal" `notElem` allExposed)
                importers "HostBootstrap.ProjectPlan.Handoff.Internal"
                    @?= [ "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.Handoff.Process.Route"
                        ]
                users "PlannedForwardHandoff"
                    @?= ["HostBootstrap.ProjectPlan.Handoff.Internal"]
                users "withPlannedForwardHandoffKernel"
                    @?= ["HostBootstrap.ProjectPlan.Handoff.Internal"]
                users "withPlannedForwardProcessInputsKernel"
                    @?= ["HostBootstrap.ProjectPlan.Handoff.Internal"]
                users "CatalogForwardHandoff"
                    @?= [ "HostBootstrap.Handoff.Process.Route"
                        , "HostBootstrap.ProjectPlan.Handoff.Internal"
                        ]
                users "withCatalogForwardHandoffKernel"
                    @?= [ "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.ProjectPlan.Handoff.Internal"
                        ]
                users "withCatalogForwardProcessInputsKernel"
                    @?= [ "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.Handoff.Process.Route"
                        , "HostBootstrap.ProjectPlan.Handoff.Internal"
                        ]
                importedByHandoff
                    @?= sort
                        [ "Data.ByteString"
                        , "Data.Text"
                        , "Data.Text"
                        , "HostBootstrap.Config.Class"
                        , "HostBootstrap.Config.Schema"
                        , "HostBootstrap.Context"
                        , "HostBootstrap.Handoff"
                        , "HostBootstrap.Lifecycle.Context.Internal"
                        , "HostBootstrap.Lifecycle.Plan"
                        , "HostBootstrap.Lifecycle.RootedPlan"
                        , "HostBootstrap.Lift.Context"
                        , "HostBootstrap.ProjectPlan.Construct.Internal"
                        , "HostBootstrap.ProjectPlan.Frame"
                        , "HostBootstrap.ProjectPlan.Projection.Internal"
                        , "HostBootstrap.Step"
                        ]
                mapM_
                    ( \dependency ->
                        case [ source
                             | (moduleName, _path, source) <- sources
                             , moduleName == dependency
                             ] of
                            [dependencySource] ->
                                assertBool
                                    (dependency <> " reverses the planned-forward dependency DAG")
                                    ( not
                                        ( SourceGuard.importsModule
                                            "HostBootstrap.ProjectPlan.Handoff.Internal"
                                            dependencySource
                                        )
                                    )
                            observed ->
                                assertFailure
                                    ( "expected one production source for "
                                        <> dependency
                                        <> ", observed "
                                        <> show (length observed)
                                    )
                    )
                    [ "HostBootstrap.Config.Schema"
                    , "HostBootstrap.Context"
                    , "HostBootstrap.Handoff"
                    , "HostBootstrap.Lifecycle.Context.Internal"
                    , "HostBootstrap.Lifecycle.Plan"
                    , "HostBootstrap.Lifecycle.RootedPlan"
                    , "HostBootstrap.Lift.Context"
                    , "HostBootstrap.ProjectPlan.Construct.Internal"
                    , "HostBootstrap.ProjectPlan.Frame"
                    , "HostBootstrap.ProjectPlan.Projection.Internal"
                    , "HostBootstrap.Step"
                    ]
                SourceGuard.countHaskellTokenSequence ["data", "PlannedForwardHandoff"] handoffSource @?= 1
                SourceGuard.countHaskellTokenSequence ["data", "CatalogForwardHandoff"] handoffSource @?= 1
                SourceGuard.countHaskellIdentifier "data" handoffSource @?= 2
                SourceGuard.countHaskellIdentifier "newtype" handoffSource @?= 0
                assertContains
                    "the package has exactly eight nominal phantom authorities"
                    "type role PlannedForwardHandoff nominal nominal nominal nominal nominal nominal nominal nominal"
                    handoff
                assertContains
                    "the hidden constructor retains both exact plans, currents, context, route views, binding input, and payload"
                    "PlannedForwardHandoff :: ProjectPlan scope specDigest parentPlanId parentConfigId cfg -> CurrentFrame scope parentPlanId parentFrame -> ValidatedLifecycleContext scope specDigest parentPlanId parentConfigId parentFrame -> ProjectPlan scope specDigest childPlanId childConfigId cfg -> PlanDigestBinding scope specDigest childPlanDigest childPlanId -> CurrentFrame scope childPlanId childFrame -> LiftContext -> LiftContext -> HandoffBindingInput -> ByteString -> PlannedForwardHandoff scope specDigest parentPlanId parentConfigId parentFrame childPlanDigest childConfigId childFrame"
                    handoff
                assertContains
                    "the sole producer accepts only the exact finalized projector and parent evidence"
                    "withPlannedForwardHandoffKernel :: (ProjectCfg cfg) => FinalizedProjectSpec scope specDigest cfg -> ProjectPlan scope specDigest parentPlanId parentConfigId cfg -> CurrentFrame scope parentPlanId parentFrame -> ValidatedLifecycleContext scope specDigest parentPlanId parentConfigId parentFrame -> ( forall childPlanDigest childConfigId childFrame. PlannedForwardHandoff scope specDigest parentPlanId parentConfigId parentFrame childPlanDigest childConfigId childFrame -> IO (Either Text ()) ) -> IO (Either Text ())"
                    handoff
                assertFragmentsInOrder
                    "the lifecycle join and its frame evidence precede the shared projection kernel"
                    [ "case withValidatedRootLifecycleContext lifecycle borrow of"
                    , "Left (LifecycleContextRootFrameRequired _)"
                    , "withValidatedNestedLifecycleContext lifecycle borrow"
                    , "borrow _ _ retainedCurrent projectFrame validated ="
                    , "admitLifecycle retainedCurrent (projectFrameId projectFrame) (validatedContextValue validated)"
                    , "suppliedId /= retainedId || suppliedId /= projectId"
                    , "withImmediateTargetKernel finalized parent suppliedCurrent parentContext sealPlanned"
                    , "suppliedId = currentFrameId suppliedCurrent"
                    , "retainedId = currentFrameId retainedCurrent"
                    ]
                    handoff
                assertContains
                    "the package is sealed only from the shared kernel's own admitted target evidence"
                    "sealPlanned targetPlan binding targetCurrent _child _parentFrame _childFrame raw route payload _configDigest _payloadDigest input = runPlannedForward ( PlannedForwardHandoff parent suppliedCurrent lifecycle targetPlan binding targetCurrent raw route input payload ) use"
                    handoff
                assertContains
                    "the Process fold exposes only the sanitized route, exact input, and canonical payload"
                    "withPlannedForwardProcessInputsKernel planned use = runPlannedForward planned expose where expose (PlannedForwardHandoff _ _ _ _ _ _ _ route input payload) = use route input payload"
                    handoff
                assertContains
                    "all ten retained fields are forced before either callback"
                    "runPlannedForward planned@(PlannedForwardHandoff parent current lifecycle targetPlan binding child raw route input payload) use = parent `seq` current `seq` lifecycle `seq` targetPlan `seq` binding `seq` child `seq` raw `seq` route `seq` input `seq` payload `seq` use planned"
                    handoff
                assertContains
                    "the catalog package has exactly eight nominal phantom authorities"
                    "type role CatalogForwardHandoff nominal nominal nominal nominal nominal nominal nominal nominal"
                    handoff
                assertContains
                    "the catalog package retains no lifecycle context, parent plan, or specification index"
                    "CatalogForwardHandoff :: (ProjectCfg cfg) => CurrentFrame scope parentPlanId parentFrame -> ProjectPlan scope specDigest childPlanId childConfigId cfg -> PlanDigestBinding scope specDigest childPlanDigest childPlanId -> CurrentFrame scope childPlanId childFrame -> Text -> Text -> LiftContext -> LiftContext -> HandoffBindingInput -> ByteString -> Text -> Text -> [OperationKey] -> CatalogForwardHandoff scope rootPlanId brokerGeneration catalogId parentFrame childPlanDigest childConfigId childFrame"
                    handoff
                assertContains
                    "the sole catalog producer takes only the catalog and the requested edge coordinates"
                    "withCatalogForwardHandoffKernel :: RootedPlanCatalog scope rootPlanId brokerGeneration catalogId -> Text -> Text -> ( forall parentFrame childPlanDigest childConfigId childFrame. CatalogForwardHandoff scope rootPlanId brokerGeneration catalogId parentFrame childPlanDigest childConfigId childFrame -> IO (Either Text ()) ) -> IO (Either Text ())"
                    handoff
                assertFragmentsInOrder
                    "catalog selection precedes every frame, configuration, digest, and route recheck"
                    [ "case withRootedPlanCatalogEdgeKernel catalog requestedParent requestedChild sealCatalog of"
                    , "Left failure -> pure (Left (catalogFailure failure))"
                    , "Right action -> action"
                    , "sealCatalog parentCurrent childPlan binding childCurrent raw route payload configDigest payloadDigest keys"
                    , "currentFrameId childCurrent /= requestedChild"
                    , "Context.currentFrame (cfgContext (validatedConfigValue childConfig)) /= requestedChild"
                    , "validatedConfigDigest childConfig /= configDigest"
                    , "configDigest /= payloadDigest"
                    , "childConfigDigest payload /= payloadDigest"
                    , "planDigestBindingDigestKernel binding /= renderedChildPlanDigest"
                    , "not (oneLayer raw) || not (oneLayer route)"
                    , "runCatalogForward"
                    ]
                    handoff
                assertFragmentsInOrder
                    "the binding input is rebuilt only from admitted evidence"
                    [ "childConfig = projectPlanValidatedConfigKernel childPlan"
                    , "renderedChildPlanDigest = stablePlanSnapshotDigestKernel (renderSnapshotKernel childPlan)"
                    , "requestedSpecDigest = validatedConfigSpecDigest childConfig"
                    , "requestedPayloadKind = NarrowedProjectConfig"
                    , "requestedPlanRevision = planDigestBindingDigestKernel binding"
                    , "requestedParentFrame = requestedParent"
                    , "requestedChildFrame = requestedChild"
                    , "requestedChildConfigDigest = configDigest"
                    , "requestedPhase = \"execute\""
                    ]
                    handoff
                assertContains
                    "the catalog Process fold exposes only the stripped route, exact input, and canonical payload"
                    "withCatalogForwardProcessInputsKernel package use = runCatalogForward package expose where expose (CatalogForwardHandoff _ _ _ _ _ _ _ route input payload _ _ _) = use route input payload"
                    handoff
                assertContains
                    "all thirteen retained catalog fields are forced before either callback"
                    "runCatalogForward package@(CatalogForwardHandoff parentCurrent childPlan binding childCurrent parent child raw route input payload configDigest payloadDigest keys) use = parentCurrent `seq` childPlan `seq` binding `seq` childCurrent `seq` parent `seq` child `seq` raw `seq` route `seq` input `seq` payload `seq` configDigest `seq` payloadDigest `seq` keys `seq` use package"
                    handoff
                assertContains
                    "both admitted routes are held to exactly one lift layer"
                    "oneLayer (LiftContext [_]) = True oneLayer _ = False"
                    handoff
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier handoffSource @?= 0)
                    [ "withRootedPlanCatalogKernel"
                    , "withRootedPlanCatalogRootKernel"
                    , "withRootedPlanCatalogEntriesKernel"
                    , "withRootedPlanCatalogEntryKernel"
                    , "rootedPlanCatalogManifestKernel"
                    , "rootedPlanCatalogManifestMatchesKernel"
                    , "rootedPlanCatalogRecordIdentityKernel"
                    , "RootedPlanCatalogRoot"
                    , "RootedPlanCatalogDescent"
                    ]
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier handoffSource @?= 0)
                    [ "HandoffBinding"
                    , "SelfRef"
                    , "CanonicalProjectRoot"
                    , "CreateProcess"
                    , "createProcess"
                    , "runAuthorizedChildCursorKernel"
                    , "registerHandoffEdge"
                    , "grantHandoff"
                    , "verifyHandoff"
                    , "withRootBroker"
                    , "openBinaryFile"
                    , "forkIO"
                    , "withProjectedProjectPlanKernel"
                    , "withFinalizedForwardChildProjectionKernel"
                    , "renderScopedProjectConfigBytes"
                    , "deriveContainerContext"
                    ]
                mapM_
                    ( \moduleName ->
                        assertBool
                            ("planned-forward package imports runtime owner " <> moduleName)
                            (not (SourceGuard.importsModule moduleName handoffSource))
                    )
                    [ "HostBootstrap.Chain"
                    , "HostBootstrap.Command"
                    , "HostBootstrap.Handoff.Protocol"
                    , "HostBootstrap.Handoff.Receiver"
                    , "HostBootstrap.Handoff.Relay"
                    , "HostBootstrap.Lift"
                    , "System.IO"
                    , "System.Process"
                    ]
                sha256Text handoffBytes
                    @?= "d154e781659804d49acd9cd846767f9b5fb37c11a23ea63ffb939691ccf806e4"
                significantHaskellLineCount handoffSource @?= 304
                assertBool
                    "the forward-package owner crossed the hard 400-line split boundary"
                    (significantHaskellLineCount handoffSource < 400)
        , testCase "the shared immediate-target projection is VLC-free, exact, hidden, and acyclic" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                let planPath =
                        sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Plan.hs"
                    projectionPath =
                        sourceRoot
                            </> "HostBootstrap"
                            </> "ProjectPlan"
                            </> "Projection"
                            </> "Internal.hs"
                planBytes <- ByteString.readFile planPath
                projectionBytes <- ByteString.readFile projectionPath
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                let planSource = Text.unpack (TextEncoding.decodeUtf8 planBytes)
                    projectionSource =
                        Text.unpack (TextEncoding.decodeUtf8 projectionBytes)
                    plan = normalizeWhitespace planSource
                    projection = normalizeWhitespace projectionSource
                sources <- readProductionSources sourceRoot
                librarySource <-
                    maybe
                        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                        pure
                        (mainLibraryStanza cabalSource)
                projectionExports <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan.Projection.Internal"
                        projectionSource
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                let exposed = fieldModules "exposed-modules:" librarySource
                    allExposed = fieldModules "exposed-modules:" cabalSource
                    privateModules = fieldModules "other-modules:" librarySource
                    users identifier =
                        sort
                            [ moduleName
                            | (moduleName, _path, source) <- sources
                            , SourceGuard.countHaskellIdentifier identifier source > 0
                            ]
                    importers moduleName =
                        sort
                            [ importer
                            | (importer, _path, source) <- sources
                            , SourceGuard.importsModule moduleName source
                            ]
                    sprintOwners =
                        sort
                            [ moduleName
                            | (moduleName, _path, source) <- sources
                            , any
                                (\identifier -> SourceGuard.countHaskellIdentifier identifier source > 0)
                                [ "PlanProjectedRootInvalid"
                                , "canonicalProjectedRootKernel"
                                , "withProjectedProjectPlanKernel"
                                , "PlannedForwardHandoff"
                                , "withPlannedForwardHandoffKernel"
                                ]
                            ]
                filter (/= ",") projectionExports @?= ["withImmediateTargetKernel"]
                modulesExporting "withImmediateTargetKernel" publicExports @?= []
                length
                    (filter (== "HostBootstrap.ProjectPlan.Projection.Internal") privateModules)
                    @?= 1
                assertBool
                    "the shared projection kernel appears in the main exposed modules"
                    ("HostBootstrap.ProjectPlan.Projection.Internal" `notElem` exposed)
                assertBool
                    "the shared projection kernel is exposed by another Cabal component"
                    ("HostBootstrap.ProjectPlan.Projection.Internal" `notElem` allExposed)
                importers "HostBootstrap.ProjectPlan.Projection.Internal"
                    @?= [ "HostBootstrap.Command.Child"
                        , "HostBootstrap.Lifecycle.RootedPlan"
                        , "HostBootstrap.ProjectPlan.Handoff.Internal"
                        ]
                users "withImmediateTargetKernel"
                    @?= [ "HostBootstrap.Command.Child"
                        , "HostBootstrap.Lifecycle.RootedPlan"
                        , "HostBootstrap.ProjectPlan.Handoff.Internal"
                        , "HostBootstrap.ProjectPlan.Projection.Internal"
                        ]
                users "withProjectedProjectPlanKernel"
                    @?= [ "HostBootstrap.Lifecycle.Plan"
                        , "HostBootstrap.ProjectPlan.Projection.Internal"
                        ]
                sprintOwners
                    @?= [ "HostBootstrap.Lifecycle.Plan"
                        , "HostBootstrap.ProjectPlan.Handoff.Internal"
                        , "HostBootstrap.ProjectPlan.Projection.Internal"
                        ]
                sort (SourceGuard.haskellImports projectionSource)
                    @?= sort
                        [ "Data.ByteString"
                        , "Data.List.NonEmpty"
                        , "Data.Text"
                        , "Data.Text"
                        , "Data.Text.Encoding"
                        , "HostBootstrap.Config.Class"
                        , "HostBootstrap.Config.Schema"
                        , "HostBootstrap.Config.Vocab"
                        , "HostBootstrap.Context"
                        , "HostBootstrap.Handoff"
                        , "HostBootstrap.Lifecycle.Plan"
                        , "HostBootstrap.Lift.Context"
                        , "HostBootstrap.ProjectPlan.Construct.Internal"
                        , "HostBootstrap.ProjectPlan.Frame"
                        ]
                SourceGuard.countHaskellIdentifier "data" projectionSource @?= 0
                SourceGuard.countHaskellIdentifier "newtype" projectionSource @?= 0
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier projectionSource @?= 0)
                    [ "ValidatedLifecycleContext"
                    , "withValidatedRootLifecycleContext"
                    , "withValidatedNestedLifecycleContext"
                    , "ProtectedStore"
                    , "CanonicalProjectRoot"
                    , "RootInvocationAuthority"
                    , "RootedPlanCatalog"
                    , "CreateProcess"
                    , "createProcess"
                    , "readFile"
                    , "writeFile"
                    ]
                assertContains
                    "the shared kernel takes only VLC-free parent evidence and one admitted context"
                    "withImmediateTargetKernel :: (ProjectCfg cfg) => FinalizedProjectSpec scope specDigest cfg -> ProjectPlan scope specDigest parentPlanId parentConfigId cfg -> CurrentFrame scope parentPlanId parentFrame -> Context.BinaryContext -> ( forall childPlanDigest childPlanId childConfigId childFrame. ProjectPlan scope specDigest childPlanId childConfigId cfg -> PlanDigestBinding scope specDigest childPlanDigest childPlanId -> CurrentFrame scope childPlanId childFrame -> Context.BinaryContext -> Text -> Text -> LiftContext -> LiftContext -> ByteString -> Text -> Text -> HandoffBindingInput -> IO (Either Text ()) ) -> IO (Either Text ())"
                    projection
                assertFragmentsInOrder
                    "frame, admitted-config, topology, and placement joins precede edge selection"
                    [ "parentFrameId /= Context.currentFrame parentContext"
                    , "cfgContext (validatedConfigValue parentConfig) /= parentContext"
                    , "Context.validateTopology parentContext"
                    , "Context.contextPlacement parentContext"
                    , "topologyDescentEdgesKernel (topologyKernel parent)"
                    , "edgeParent == parentFrameId"
                    , "[(child, rawRoute@(LiftContext [_]))]"
                    , "withFinalizedForwardChildProjectionKernel finalized parentConfig parentFrameId child rawRoute"
                    , "admitProjection placement child rawRoute"
                    ]
                    projection
                assertFragmentsInOrder
                    "the fixed projector yields canonical child config before independent target-plan admission"
                    [ "descriptor childConfig childPlan"
                    , "cfgContext (validatedConfigValue childConfig) /= expected"
                    , "Context.sourceRoot expected /= Text.pack descriptor"
                    , "Context.currentFrame expected /= child"
                    , "renderScopedProjectConfigBytes (finalizedProjectCodecKernel finalized) (validatedConfigValue childConfig)"
                    , "childConfigDigest payload /= validatedConfigDigest childConfig"
                    , "withProjectedProjectPlanKernel parent descriptor childConfig childPlan"
                    , "sealTarget placement expected child rawRoute payload childConfig"
                    ]
                    projection
                assertContains
                    "the projected-plan kernel fixes child plan and digest identities under one continuation"
                    "withProjectedProjectPlanKernel :: ProjectPlan scope specDigest parentPlanId parentConfigId cfg -> FilePath -> ValidatedConfig scope specDigest childConfigId (cfg scope) -> StepPlan -> ( forall childPlanDigest childPlanId. ProjectPlan scope specDigest childPlanId childConfigId cfg -> PlanDigestBinding scope specDigest childPlanDigest childPlanId -> result ) -> Either PlanError result"
                    plan
                assertFragmentsInOrder
                    "projected admission validates POSIX descriptors and inherits every parent profile term"
                    [ "not (canonicalProjectedRootKernel descriptor)"
                    , "Left (PlanProjectedRootInvalid descriptor)"
                    , "admitProjectPlanAtRootKernel (projectPlanProfileNameKernel parent) (projectPlanProfileEpochKernel parent) (projectPlanProfileProjectNameKernel parent) (projectPlanProfileStoreIdentityKernel parent) descriptor config (planDraftsAtRoot descriptor config plan)"
                    , "projectPlanIndexedSnapshotKernel admitted"
                    , "projectPlanDigestKernel admitted"
                    , "use admitted (mintPlanDigestBindingKernel snapshot digest)"
                    , "Posix.isAbsolute descriptor"
                    , "Posix.isValid descriptor"
                    , "'\\\\' `notElem` descriptor"
                    , "all (`notElem` [\".\", \"..\"]) (Posix.splitDirectories descriptor)"
                    , "Posix.normalise descriptor == descriptor"
                    , "descriptor == \"/\" || not (Posix.hasTrailingPathSeparator descriptor)"
                    ]
                    plan
                assertFragmentsInOrder
                    "ancestry comparison deliberately takes only the child prefix"
                    [ "contextIds = map Context.topologyFrameId (Context.topologyFrames childContext)"
                    , "parentFrames = take (length contextIds)"
                    , "targetFrames = take (length contextIds)"
                    , "parentEdges = take (length contextEdges)"
                    , "targetEdges = take (length contextEdges)"
                    , "parentDescents = take (length contextEdges)"
                    , "targetDescents = take (length contextEdges)"
                    ]
                    projection
                assertFragmentsInOrder
                    "ancestry labels, IDs, edges, prior lifts, and selected lift are joined independently"
                    [ "require (parentFrames == targetFrames)"
                    , "map fst parentFrames == contextIds && map fst targetFrames == contextIds"
                    , "parentEdges == contextEdges && targetEdges == contextEdges"
                    , "map edgePair parentDescents == contextEdges && map edgePair targetDescents == contextEdges"
                    , "map descentLift parentAncestors == map descentLift targetAncestors"
                    , "selectedLiftMatches placement parentLift targetLift"
                    ]
                    projection
                mapM_
                    (\fragment -> assertContains "all exact VM derivations remain closed" fragment projection)
                    [ "deriveVMContextWithProvider Context.IncusVMProvider parent root"
                    , "deriveVMContextWithProvider Context.LimaVMProvider parent root"
                    , "deriveVMContextWithProvider Context.Wsl2VMProvider parent root"
                    , "deriveLinuxGpuContainerContext parent root"
                    , "deriveContainerContext parent root"
                    , "require (parent == targetRoute) \"the selected VM or VM-container lift differs\""
                    ]
                assertFragmentsInOrder
                    "direct host-container projection preserves every field and rebases one unambiguous durable source"
                    [ "clImage parent == clImage targetContainer"
                    , "clExtraArgs parent == clExtraArgs targetContainer"
                    , "clRemoveAfter parent == clRemoveAfter targetContainer"
                    , "clConfigDelivery parent == clConfigDelivery targetContainer"
                    , "length parentMounts == length targetMounts"
                    , "filter (== dockerSocket) parentMounts == [dockerSocket]"
                    , "filter (== dockerSocket) targetMounts == [dockerSocket]"
                    , "case [(old, new) | (old, new) <- zip parentMounts targetMounts, old /= new] of [(old, new)]"
                    , "writable parentMounts == [old] && writable targetMounts == [new]"
                    , "target old == target new"
                    , "target new /= \"/var/run/docker.sock\""
                    , "not (Text.null (source old))"
                    , "source new == target new"
                    , "canonical (source new) && canonical (target new)"
                    , "_ -> refusal \"direct route must rebase exactly one mount source\""
                    , "dockerSocket = Mount \"/var/run/docker.sock\" \"/var/run/docker.sock\" False"
                    , "writable = filter (\\mount -> mount /= dockerSocket && not (readOnly mount))"
                    ]
                    projection
                assertFragmentsInOrder
                    "the canonical payload binds exact execute input before route sanitization"
                    [ "requestedSpecDigest = validatedConfigSpecDigest childConfig"
                    , "requestedPayloadKind = NarrowedProjectConfig"
                    , "requestedPlanRevision = planDigestBindingDigestKernel binding"
                    , "requestedParentFrame = parentFrameId"
                    , "requestedChildFrame = child"
                    , "requestedChildConfigDigest = validatedConfigDigest childConfig"
                    , "requestedPhase = \"execute\""
                    , "TextEncoding.encodeUtf8 (cdPayload delivery) == payload"
                    , "Nothing -> refusal \"container handoff has no canonical config delivery\""
                    , "containerPayloadMatches _ _ = Right ()"
                    , "LiftContext [ViaContainer container{clConfigDelivery = Nothing}]"
                    , "withoutConfigDelivery route = route"
                    ]
                    projection
                mapM_
                    ( \moduleName ->
                        assertBool
                            ("shared projection kernel imports runtime owner " <> moduleName)
                            (not (SourceGuard.importsModule moduleName projectionSource))
                    )
                    [ "HostBootstrap.Chain"
                    , "HostBootstrap.Command"
                    , "HostBootstrap.Handoff.Protocol"
                    , "HostBootstrap.Handoff.Receiver"
                    , "HostBootstrap.Handoff.Relay"
                    , "HostBootstrap.Lift"
                    , "HostBootstrap.Lifecycle.Context.Internal"
                    , "HostBootstrap.ProjectPlan.Handoff.Internal"
                    , "System.IO"
                    , "System.Process"
                    ]
                sha256Text projectionBytes
                    @?= "9902a395b1105c1fa9ef7025a3b6a12e1d5d96addb07490e23a0d8b19c8eaef8"
                significantHaskellLineCount projectionSource @?= 274
        , testCase "the recursive rooted plan catalog is nominal, hidden, fold-only, and inert" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                let catalogPath =
                        sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "RootedPlan.hs"
                catalogBytes <- ByteString.readFile catalogPath
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                let catalogSource = Text.unpack (TextEncoding.decodeUtf8 catalogBytes)
                    catalog = normalizeWhitespace catalogSource
                sources <- readProductionSources sourceRoot
                librarySource <-
                    maybe
                        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                        pure
                        (mainLibraryStanza cabalSource)
                catalogExports <-
                    requiredModuleExports
                        "HostBootstrap.Lifecycle.RootedPlan"
                        catalogSource
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                let exposed = fieldModules "exposed-modules:" librarySource
                    allExposed = fieldModules "exposed-modules:" cabalSource
                    privateModules = fieldModules "other-modules:" librarySource
                    importers moduleName =
                        sort
                            [ importer
                            | (importer, _path, source) <- sources
                            , SourceGuard.importsModule moduleName source
                            ]
                    catalogSignificant = significantHaskellLineCount catalogSource
                filter (/= ",") catalogExports
                    @?= [ "RootedPlanCatalog"
                        , "withRootedPlanCatalogKernel"
                        , "withRootedPlanCatalogRootKernel"
                        , "withRootedPlanCatalogEntriesKernel"
                        , "withRootedPlanCatalogEntriesContinuationKernel"
                        , "withRootedPlanCatalogEntryKernel"
                        , "withRootedPlanCatalogEdgeKernel"
                        , "rootedPlanCatalogRecordIdentityKernel"
                        , "rootedPlanCatalogManifestKernel"
                        , "rootedPlanCatalogManifestMatchesKernel"
                        ]
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "RootedPlanCatalog"
                    , "withRootedPlanCatalogKernel"
                    , "withRootedPlanCatalogRootKernel"
                    , "withRootedPlanCatalogEntriesKernel"
                    , "withRootedPlanCatalogEntriesContinuationKernel"
                    , "withRootedPlanCatalogEntryKernel"
                    , "withRootedPlanCatalogEdgeKernel"
                    , "withRootedPlanCatalogFrameKernel"
                    , "rootedPlanCatalogRecordIdentityKernel"
                    , "rootedPlanCatalogManifestKernel"
                    , "rootedPlanCatalogManifestMatchesKernel"
                    ]
                length
                    (filter (== "HostBootstrap.Lifecycle.RootedPlan") privateModules)
                    @?= 1
                assertBool
                    "the recursive catalog appears in the main exposed modules"
                    ("HostBootstrap.Lifecycle.RootedPlan" `notElem` exposed)
                assertBool
                    "the recursive catalog is exposed by another Cabal component"
                    ("HostBootstrap.Lifecycle.RootedPlan" `notElem` allExposed)
                importers "HostBootstrap.Lifecycle.RootedPlan"
                    @?= [ "HostBootstrap.Authority.FailedUp.Internal"
                        , "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.Lifecycle.Rooted"
                        , "HostBootstrap.ProjectPlan.Handoff.Internal"
                        , "HostBootstrap.Teardown.Internal"
                        ]
                sort (SourceGuard.haskellImports catalogSource)
                    @?= sort
                        [ "Data.Bits"
                        , "Data.ByteString"
                        , "Data.ByteString"
                        , "Data.List.NonEmpty"
                        , "Data.Text"
                        , "Data.Text"
                        , "Data.Text.Encoding"
                        , "Data.Word"
                        , "HostBootstrap.Authority.Kernel"
                        , "HostBootstrap.Config.Class"
                        , "HostBootstrap.Context"
                        , "HostBootstrap.Lifecycle.Context.Internal"
                        , "HostBootstrap.Lifecycle.Plan"
                        , "HostBootstrap.Lift.Context"
                        , "HostBootstrap.ProjectPlan.Construct.Internal"
                        , "HostBootstrap.ProjectPlan.Frame"
                        , "HostBootstrap.ProjectPlan.Projection.Internal"
                        , "HostBootstrap.Step"
                        ]
                SourceGuard.countHaskellTokenSequence ["data", "RootedPlanCatalog"] catalogSource @?= 1
                SourceGuard.countHaskellIdentifier "data" catalogSource @?= 1
                SourceGuard.countHaskellIdentifier "newtype" catalogSource @?= 0
                SourceGuard.countHaskellIdentifier "type" catalogSource @?= 1
                assertContains
                    "the catalog has exactly four nominal phantom authorities"
                    "type role RootedPlanCatalog nominal nominal nominal nominal"
                    catalog
                assertContains
                    "the sole producer consumes the exact specification, authority, root plan, frame, and lifecycle context"
                    "withRootedPlanCatalogKernel :: (ProjectCfg cfg) => FinalizedProjectSpec scope specDigest cfg -> RootInvocationAuthority scope brokerGeneration verb -> ProjectPlan scope specDigest rootPlanId rootConfigId cfg -> CurrentFrame scope rootPlanId rootFrame -> ValidatedLifecycleContext scope specDigest rootPlanId rootConfigId rootFrame -> ( forall catalogId. RootedPlanCatalog scope rootPlanId brokerGeneration catalogId -> IO (Either Text ()) ) -> IO (Either Text ())"
                    catalog
                assertFragmentsInOrder
                    "root residency, frame evidence, and authority identity precede any projection"
                    [ "case withValidatedRootLifecycleContext lifecycle borrow of"
                    , "borrow _ _ retainedCurrent projectFrame validated ="
                    , "admitRoot retainedCurrent (projectFrameId projectFrame) (validatedContextValue validated)"
                    , "rootId /= currentFrameId retainedCurrent || rootId /= projectId"
                    , "rootId /= Context.currentFrame rootContext"
                    , "rootAuthorityProjectName authority /= projectPlanProfileProjectNameKernel rootPlan"
                    , "rootAuthorityStoreIdentity authority /= projectPlanProfileStoreIdentityKernel rootPlan"
                    , "descendRootedPlanCatalogKernel finalized"
                    , "RootedPlanCatalogRoot finalized authority rootPlan rootCurrent lifecycle"
                    , "rootId = currentFrameId rootCurrent"
                    ]
                    catalog
                assertFragmentsInOrder
                    "descent is topology-terminated, depth-bounded, and driven only by the shared kernel"
                    [ "case topologyDescentFromKernel (topologyKernel plan) frameName of"
                    , "Nothing -> use catalog"
                    , "budget <= 0"
                    , "the recursive catalog exceeds the root topology depth"
                    , "withImmediateTargetKernel finalized plan current context extend"
                    , "frameName = currentFrameId current"
                    , "extend targetPlan binding targetCurrent childContext parentFrame childFrame raw route payload configDigest payloadDigest _input"
                    , "descendRootedPlanCatalogKernel finalized (budget - 1) ( RootedPlanCatalogDescent catalog targetPlan binding targetCurrent parentFrame childFrame raw route payload configDigest payloadDigest (projectedNodeKeys plan parentFrame) ) targetPlan targetCurrent childContext use"
                    ]
                    catalog
                assertContains
                    "projected node keys come only from the parent plan's own indexed steps"
                    "projectedNodeKeys plan frameName = concat [ plannedStepProjectedOperationKeysKernel step | step <- NonEmpty.toList (forwardKernel plan) , plannedStepFrameIdKernel step == frameName ]"
                    catalog
                assertContains
                    "entries are folded in canonical root-first order"
                    "withRootedPlanCatalogEntriesKernel catalog use = collect catalog [] where collect (RootedPlanCatalogRoot _ _ _ _ _) collected = collected"
                    catalog
                assertContains
                    "selection is a fold over the catalog itself"
                    "select (RootedPlanCatalogRoot _ _ _ _ _) = Nothing"
                    catalog
                assertContains
                    "the edge fold discloses the parent level only as its own frame identity"
                    "withRootedPlanCatalogEdgeKernel :: RootedPlanCatalog scope rootPlanId brokerGeneration catalogId -> Text -> Text -> ( forall parentPlanId parentFrame specDigest childPlanDigest childPlanId childConfigId childFrame cfg. (ProjectCfg cfg) => CurrentFrame scope parentPlanId parentFrame -> ProjectPlan scope specDigest childPlanId childConfigId cfg -> PlanDigestBinding scope specDigest childPlanDigest childPlanId -> CurrentFrame scope childPlanId childFrame -> LiftContext -> LiftContext -> ByteString -> Text -> Text -> [OperationKey] -> result ) -> Either Text result"
                    catalog
                assertFragmentsInOrder
                    "missing, duplicate, sibling, and independently projected edges all refuse before the fold"
                    [ "case collect catalog [] of"
                    , "[] -> refusal \"no admitted descent edge names the requested child frame\""
                    , "[selected] -> selected"
                    , "_ -> refusal \"more than one admitted descent edge names the requested child frame\""
                    , "child /= requestedChild = collect ancestors collected"
                    , "parent /= requestedParent = refusal \"the admitted edge names another parent frame\""
                    , "withRootedPlanCatalogFrameKernel ancestors joinParent"
                    , "currentFrameId parentCurrent /= parent"
                    , "topologyDescentFromKernel (topologyKernel parentPlan) parent /= Just (child, raw)"
                    , "projectedNodeKeys parentPlan parent /= keys"
                    , "use parentCurrent plan binding current raw route payload configDigest payloadDigest keys"
                    ]
                    catalog
                assertContains
                    "each catalog level stands on its own retained plan and current frame"
                    "RootedPlanCatalogRoot _ _ plan current _ -> use plan current RootedPlanCatalogDescent _ plan _ current _ _ _ _ _ _ _ _ -> use plan current"
                    catalog
                assertContains
                    "the durable record identity carries only the root plan's own lineage"
                    "\"catalog/\" <> projectPlanProfileProjectNameKernel plan <> \"/\" <> projectPlanProfileNameKernel plan <> \"/\" <> Text.pack (show (projectPlanProfileEpochKernel plan))"
                    catalog
                assertFragmentsInOrder
                    "the manifest is bounded, length-framed, counted, and root-first"
                    [ "entryCount > rootedPlanCatalogEntryCeiling"
                    , "the recursive catalog manifest exceeds its entry ceiling"
                    , "ByteString.length rendered > rootedPlanCatalogManifestCeiling"
                    , "the recursive catalog manifest exceeds its byte ceiling"
                    , "entries = withRootedPlanCatalogEntriesKernel catalog manifestEntry"
                    , "withRootedPlanCatalogRootKernel catalog manifestRoot : manifestWord (fromIntegral entryCount) : entries"
                    , "manifestFrame \"hostbootstrap/rooted-plan-catalog\""
                    , "manifestText (stablePlanSnapshotSpecDigestKernel snapshot)"
                    , "manifestText (stablePlanSnapshotDigestKernel snapshot)"
                    , "manifestText (currentFrameId current)"
                    , "manifestEntry plan binding _current parent child _raw _route _payload configDigest payloadDigest keys"
                    , "manifestText (planDigestBindingDigestKernel binding)"
                    , "manifestWord (fromIntegral (length keys))"
                    ]
                    catalog
                assertContains
                    "readback is strict equality over the complete canonical bytes"
                    "Right expected | expected == observed -> Right () | otherwise -> refusal \"the durable recursive catalog manifest differs from the admitted catalog\""
                    catalog
                assertContains
                    "every variable-width manifest value is length-framed"
                    "manifestFrame value = manifestWord (fromIntegral (ByteString.length value)) <> value"
                    catalog
                assertBool
                    "the manifest renders a raw configuration payload"
                    (not ("manifestFrame payload" `isInfixOf` catalog))
                assertContains
                    "the admitted-edge ceiling is fixed"
                    "rootedPlanCatalogEntryCeiling = 64"
                    catalog
                assertContains
                    "the manifest byte ceiling is fixed"
                    "rootedPlanCatalogManifestCeiling = 65536"
                    catalog
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier catalogSource @?= 0)
                    [ "withValidatedNestedLifecycleContext"
                    , "ProtectedStore"
                    , "CanonicalProjectRoot"
                    , "PlannedForwardHandoff"
                    , "CreateProcess"
                    , "createProcess"
                    , "readFile"
                    , "writeFile"
                    , "IORef"
                    , "newIORef"
                    , "unsafePerformIO"
                    , "compareAndSwapProtectedRecord"
                    , "withProtectedEntry"
                    , "AcquisitionJournal"
                    , "LifecycleCursor"
                    , "CommandAuthority"
                    , "signHandoff"
                    , "grantHandoff"
                    ]
                mapM_
                    ( \moduleName ->
                        assertBool
                            ("recursive catalog imports runtime owner " <> moduleName)
                            (not (SourceGuard.importsModule moduleName catalogSource))
                    )
                    [ "HostBootstrap.Chain"
                    , "HostBootstrap.Command"
                    , "HostBootstrap.Handoff"
                    , "HostBootstrap.Handoff.Protocol"
                    , "HostBootstrap.Handoff.Receiver"
                    , "HostBootstrap.Handoff.Relay"
                    , "HostBootstrap.Lift"
                    , "HostBootstrap.Protected"
                    , "System.IO"
                    , "System.Process"
                    ]
                sha256Text catalogBytes
                    @?= "926d23510b9142d48cc5bce9a96df83e1fe0773b553c4ce9743249c9a50a4780"
                catalogSignificant @?= 414
                assertBool
                    "the recursive catalog owner crossed the hard 425-line split boundary"
                    (catalogSignificant < 425)
        , testCase "the rooted frame session is root-selected, hidden, nominal, and request-inert" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                let rootedPath = sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Rooted.hs"
                rootedSource <- readFile rootedPath
                sessionSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Session.hs")
                catalogSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "RootedPlan.hs")
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources sourceRoot
                librarySource <-
                    maybe
                        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                        pure
                        (mainLibraryStanza cabalSource)
                rootedExports <-
                    requiredModuleExports "HostBootstrap.Lifecycle.Rooted" rootedSource
                openerSource <-
                    requiredSourceSection
                        "the root opening"
                        "withRootOpenedFrameSessionKernel ::"
                        "{- | Attach one exact 'OpenFrame' to an already opened session"
                        rootedSource
                attachSource <-
                    requiredSourceSection
                        "the OpenFrame attachment"
                        "withAttachedRootedFrameSessionKernel ::"
                        "{- | Answer one exact 'OpenFrame' from the session the root already opened."
                        rootedSource
                eliminatorSource <-
                    requiredSourceSection
                        "the fixed-unit session eliminator"
                        "withRootedFrameSessionKernel ::"
                        "rootedFrameSessionDomain ::"
                        rootedSource
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                let rooted = normalizeWhitespace rootedSource
                    opener = normalizeWhitespace openerSource
                    attach = normalizeWhitespace attachSource
                    eliminator = normalizeWhitespace eliminatorSource
                    exposed = fieldModules "exposed-modules:" librarySource
                    privateModules = fieldModules "other-modules:" librarySource
                    importers moduleName =
                        sort
                            [ importer
                            | (importer, _path, source) <- sources
                            , SourceGuard.importsModule moduleName source
                            ]
                    sites name =
                        [ (moduleName, count)
                        | (moduleName, _path, sourceBody) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name sourceBody
                        , count > 0
                        ]
                filter (/= ",") rootedExports
                    @?= [ "RootedFrameSession"
                        , "withRootOpenedFrameSessionKernel"
                        , "withRootOpenedDirectFrameSessionKernel"
                        , "withAttachedRootedFrameSessionKernel"
                        , "withRootedFrameOpeningKernel"
                        , "withRootedFrameSessionKernel"
                        , "withAdvancedRootedFrameSessionKernel"
                        , "withFailedRootedFrameSessionKernel"
                        , "cancelUnattachedRootedFrameSessionKernel"
                        ]
                assertBool
                    "the rooted frame session owner stays Cabal-private"
                    ( "HostBootstrap.Lifecycle.Rooted" `notElem` exposed
                        && length (filter (== "HostBootstrap.Lifecycle.Rooted") privateModules) == 1
                    )
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "RootedFrameSession"
                    , "OpenedRootedFrameSession"
                    , "AttachedRootedFrameSession"
                    , "withRootOpenedFrameSessionKernel"
                    , "withAttachedRootedFrameSessionKernel"
                    , "withRootedFrameOpeningKernel"
                    , "withRootedFrameSessionKernel"
                    , "cancelUnattachedRootedFrameSessionKernel"
                    ]
                assertContains
                    "the sole named type carries seven nominal roles"
                    "type role RootedFrameSession nominal nominal nominal nominal nominal nominal nominal"
                    rooted
                SourceGuard.countHaskellIdentifier "data" rootedSource @?= 1
                SourceGuard.countHaskellIdentifier "newtype" rootedSource @?= 0
                SourceGuard.countHaskellIdentifier "type" rootedSource @?= 1
                assertContains
                    "both the frame and session indices are minted by the opening"
                    "( forall frame sessionId. RootedFrameSession scope rootPlanId brokerGeneration catalogId frame sessionId verb -> IO (Either Text ()) ) -> IO (Either Text ())"
                    opener
                assertFragmentsInOrder
                    "admission gates the whole opening, so nothing durable runs before it returns"
                    [ "case admit atRoot generation runtimeVerb frame of"
                    , "Left failure -> pure (Left failure)"
                    , "Right (path, key, opened) -> do"
                    , "entered <- withProtectedEntry store"
                    , "openOrRestartDirect session path key opened"
                    , "present /= opened"
                    ]
                    opener
                assertFragmentsInOrder
                    "only an exact abandoned direct attachment is atomically replaced by this opening"
                    [ "observed <- openRootedFrameSessionRecordKernel session key opened"
                    , "present == opened -> pure (Right exact)"
                    , "direct"
                    , "validateAttachedRootedFrameSessionRow rootPlanDigest catalogIdentity path opened present"
                    , "protectedRecordVersion record == version"
                    , "protectedRecordBytes record == present"
                    , "compareAndDeleteProtectedRecord session key (ExpectVersion version)"
                    , "restarted <- openRootedFrameSessionRecordKernel session key opened"
                    , "restartedBytes == opened -> Right exact"
                    ]
                    opener
                assertFragmentsInOrder
                    "the root arm is admitted and the path and key derived inside that admission"
                    [ "require \"a keyless nested arm cannot open a root frame session\" atRoot"
                    , "require \"the runtime is not path-agnostic\" (isNothing frame)"
                    , "path <- canonicalRequesterPath"
                    , "key <- sessionFailure (rootedFrameSessionKeyKernel rootPlanDigest catalogIdentity requestedFrame)"
                    ]
                    opener
                assertFragmentsInOrder
                    "the canonical path is the catalog's own descent chain and refuses a missing or forked edge"
                    [ "withRootedPlanCatalogEntriesKernel"
                    , "rootFrame = withRootedPlanCatalogRootKernel catalog"
                    , "frame == rootFrame = Right path"
                    , "the admitted descent chain does not reach the root frame"
                    , "[parent] -> climb (remaining - 1) parent (frame : path)"
                    , "no admitted descent edge names the requested frame"
                    , "more than one admitted descent edge names the requested frame"
                    ]
                    opener
                assertContains
                    "the opened row carries the root-selected coordinates and no predecessor"
                    "framedText \"opened\" , framedText rootPlanDigest , framedText catalogIdentity , framedText requestedFrame , framedText verbName , framedText (sessionTokenFor path) , framedText initialStage , framedWord initialOrdinal"
                    opener
                assertBool
                    "the initial ordinal is nonzero and the stage is fixed"
                    ( "initialOrdinal = 1" `isInfixOf` rooted
                        && "initialStage = \"open\"" `isInfixOf` rooted
                    )
                assertFragmentsInOrder
                    "an already attached session refuses, and admission gates the durable advance"
                    [ "AttachedRootedFrameSession{} -> pure (Left (rootedFailure \"the rooted frame session is already attached\"))"
                    , "case admit atRoot frame path rootPlanDigest catalogIdentity openedBytes of"
                    , "Left failure -> pure (Left failure)"
                    , "entered <- withProtectedEntry store"
                    , "attachRootedFrameSessionRecordKernel session key version openedBytes attached"
                    ]
                    attach
                assertFragmentsInOrder
                    "attachment resolves arm, envelope, request form, and predecessor inside that admission"
                    [ "require \"a keyless nested arm cannot attach a root frame session\" atRoot"
                    , "require \"the sealed external envelope is not the session's own path\" (envelope == path)"
                    , "rootedLifecycleRequestFromWireKernel request"
                    , "withRootedLifecycleRequestKernel"
                    , "predecessor = childConfigDigest signedOpened"
                    ]
                    attach
                assertContains
                    "only an OpenFrame attaches; every post-open form refuses"
                    "postOpen = Left (rootedFailure \"only an OpenFrame request attaches a rooted frame session\")"
                    attach
                assertContains
                    "the replay identity frames root lineage, catalog, envelope path, and nonce together"
                    "framedText \"attached\" , frameWire openedBytes , framedText rootPlanDigest , framedText catalogIdentity , framedWord (fromIntegral (length path))"
                    rooted
                assertContains
                    "an opened session discloses no predecessor and an attached one discloses exactly its first"
                    "use False (projectVerbName verb) lineage catalogIdentity frame path token stage ordinal Nothing"
                    eliminator
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier rootedSource @?= 0)
                    [ "rootedRefusedResponseUnsignedKernel"
                    , "rootedPreparedResponseUnsignedKernel"
                    , "rootedFrameCompleteResponseUnsignedKernel"
                    , "rootedReceiptRecordedResponseUnsignedKernel"
                    , "signRootedLifecycleResponseKernel"
                    , "recoverySigningKernel"
                    , "ProjectSigningKey"
                    , "RootBroker"
                    , "compareAndSwapProtectedRecord"
                    , "listProtectedRecords"
                    , "createProcess"
                    , "unsafeCoerce"
                    ]
                mapM_
                    ( \moduleName ->
                        assertBool
                            ("the rooted frame session imports no command or transport owner " <> moduleName)
                            (not (SourceGuard.importsModule moduleName rootedSource))
                    )
                    [ "HostBootstrap.Chain"
                    , "HostBootstrap.Command"
                    , "HostBootstrap.Command.LifecycleEntry"
                    , "HostBootstrap.Handoff.Protocol"
                    , "HostBootstrap.Handoff.Receiver"
                    , "HostBootstrap.Handoff.Relay"
                    , "System.Process"
                    ]
                assertBool
                    "the durable session owner still names no catalog type"
                    ( not (SourceGuard.importsModule "HostBootstrap.Lifecycle.RootedPlan" sessionSource)
                        && not (SourceGuard.importsModule "HostBootstrap.Lifecycle.Rooted" sessionSource)
                        && SourceGuard.countHaskellIdentifier "RootedPlanCatalog" sessionSource == 0
                    )
                assertBool
                    "the catalog owner still names no store, session, or compare-and-swap operation"
                    ( SourceGuard.countHaskellIdentifier "ProtectedStore" catalogSource == 0
                        && SourceGuard.countHaskellIdentifier "ProtectedSession" catalogSource == 0
                        && SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" catalogSource == 0
                    )
                sites "withRootOpenedFrameSessionKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 2)
                        , ("HostBootstrap.Lifecycle.Rooted", 4)
                        ]
                sites "withRootOpenedDirectFrameSessionKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 3)
                        , ("HostBootstrap.Lifecycle.Rooted", 3)
                        ]
                sites "withAttachedRootedFrameSessionKernel"
                    @?= [("HostBootstrap.Lifecycle.Rooted", 5)]
                sites "cancelUnattachedRootedFrameSessionKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 2)
                        , ("HostBootstrap.Lifecycle.Rooted", 3)
                        ]
                sites "rootedFrameSessionKeyKernel"
                    @?= [ ("HostBootstrap.Lifecycle.Rooted", 2)
                        , ("HostBootstrap.Lifecycle.Session", 3)
                        ]
                importers "HostBootstrap.Lifecycle.Rooted"
                    @?= [ "HostBootstrap.Authority.FailedUp.Internal"
                        , "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.Handoff.Relay"
                        , "HostBootstrap.Handoff.TerminalReport"
                        , "HostBootstrap.Lifecycle.Rooted.Node"
                        , "HostBootstrap.Lifecycle.Rooted.Receipt"
                        ]
                assertBool
                    "the sprint-owned opening and attachment slices stay inside their coherent budget"
                    ( significantHaskellLineCount openerSource
                        + significantHaskellLineCount attachSource
                        < 400
                    )
        , testCase "failed-Up unwind authority is hidden, nominal, exact, and narrower than Destroy" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                authoritySource <-
                    readFile
                        ( sourceRoot
                            </> "HostBootstrap"
                            </> "Authority"
                            </> "FailedUp"
                            </> "Internal.hs"
                        )
                rootedSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Rooted.hs")
                entrySource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Command" </> "LifecycleEntry.hs")
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                authorityExports <-
                    requiredModuleExports
                        "HostBootstrap.Authority.FailedUp.Internal"
                        authoritySource
                let authority = normalizeWhitespace authoritySource
                    rooted = normalizeWhitespace rootedSource
                    entry = normalizeWhitespace entrySource
                filter (/= ",") authorityExports
                    @?= [ "FailedUpUnwindAuthority"
                        , "withFailedUpUnwindAuthorityKernel"
                        , "withRootFailedUpUnwindAuthorityKernel"
                        , "withRetriedFailedUpUnwindAuthorityKernel"
                        , "withFailedUpCleanupOperationsKernel"
                        ]
                assertContains
                    "the authority is the sprint's one four-index nominal type"
                    "data FailedUpUnwindAuthority scope rootPlanId brokerGeneration catalogId = FailedUpUnwindAuthority"
                    authority
                assertContains
                    "all four authority indices are nominal"
                    "type role FailedUpUnwindAuthority nominal nominal nominal nominal"
                    authority
                assertContains
                    "only exact Up root authority enters the producer"
                    "RootInvocationAuthority scope brokerGeneration VerbUp -> RootedPlanCatalog scope rootPlanId brokerGeneration catalogId -> RootedFrameSession scope rootPlanId brokerGeneration sessionCatalogId frame sessionId VerbUp"
                    authority
                mapM_
                    (\fragment -> assertContains "failed-Up authority retains every coordinate check" fragment authority)
                    [ "nub reached == reached"
                    , "all (`elem` reached) unresolved"
                    , "sessionCatalog == catalogIdentity"
                    , "rootAuthorityProjectName catalogRoot == project"
                    , "brokerEpochWord (rootAuthorityEpoch catalogRoot) == epoch"
                    , "lineage == stablePlanSnapshotDigest (renderSnapshot plan)"
                    , "sameAuthority retained candidate"
                    ]
                assertAbsent "failed-Up authority cannot name Destroy authority" "VerbDestroy" authoritySource
                assertAbsent "failed-Up authority cannot mutate Production mode" "HostBootstrap.Lifecycle.Mode" authoritySource
                assertAbsent "failed-Up authority cannot open the store" "HostBootstrap.Protected" authoritySource
                assertContains
                    "only an attached closed Up session can contribute a failure witness"
                    "projectVerbName verb /= \"up\" -> refused \"the failed session is not an Up session\" | stage `notElem` [\"refused\", \"frame-complete\", \"receipt-recorded\"] -> refused \"the failed session has not reached a terminal failure stage\""
                    rooted
                assertContains
                    "the authority also consumes the exact canonical failed report and admitted binding"
                    "eliminateLifecycleReport report wrong wrong failedReport wrong wrong wrong"
                    authority
                assertContains
                    "the sealed Entry wrapper admits only its root Up constructor"
                    "case entry of RootUpLifecycleEntry root _ _ _ _ _ _ catalog -> withFailedUpUnwindAuthorityKernel root catalog failed report binding reached unresolved use ChildUpLifecycleEntry{} -> refused"
                    entry
                assertContains
                    "the hidden module is built but not exposed"
                    "other-modules: HostBootstrap.CLI.Bare HostBootstrap.Authority.Kernel HostBootstrap.Authority.FailedUp.Internal"
                    (normalizeWhitespace cabalSource)
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                modulesExporting "FailedUpUnwindAuthority" publicExports @?= []
                assertBool
                    "the three sprint-owned additions stay within their coherent budget"
                    ( significantHaskellLineCount authoritySource
                        + SourceGuard.countHaskellIdentifier "withFailedRootedFrameSessionKernel" rootedSource
                        + SourceGuard.countHaskellIdentifier "withFailedUpUnwindAuthorityForEntryKernel" entrySource
                        < 400
                    )
        , testCase "the rooted opening signs the root's own coordinates and records before it releases" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                rootedSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Rooted.hs")
                runtimeSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Runtime.hs")
                relaySource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
                sources <- readProductionSources sourceRoot
                runtimeExports <-
                    requiredModuleExports "HostBootstrap.Handoff.Runtime" runtimeSource
                openingSource <-
                    requiredSourceSection
                        "the rooted frame opening"
                        "withRootedFrameOpeningKernel ::"
                        "{- | Read one session's root-selected coordinates"
                        rootedSource
                rootArmSource <-
                    requiredSourceSection
                        "the root-arm runtime fold"
                        "withRootArmRecursiveHandoffRuntimeKernel ::"
                        "requireIdentity ::"
                        runtimeSource
                callSiteSource <-
                    requiredSourceSection
                        "the rooted opening call site"
                        "withRootedOpenedResponseKernel ::"
                        "openingFailure ::"
                        relaySource
                endpointSource <-
                    requiredSourceSection
                        "the live root endpoint"
                        "rootBrokerLink ::"
                        "{- | Every other frame's link"
                        relaySource
                serviceSource <-
                    requiredSourceSection
                        "the rooted lifecycle endpoint shape"
                        "type RootedLifecycleService ="
                        "{- | A frame's route to the root-owned capabilities."
                        relaySource
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                let opening = normalizeWhitespace openingSource
                    rootArm = normalizeWhitespace rootArmSource
                    callSite = normalizeWhitespace callSiteSource
                    endpoint = normalizeWhitespace endpointSource
                    service = normalizeWhitespace serviceSource
                    sites name =
                        [ (moduleName, count)
                        | (moduleName, _path, sourceBody) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name sourceBody
                        , count > 0
                        ]
                filter (/= ",") runtimeExports
                    @?= [ "RecursiveHandoffRuntime"
                        , "rootRecursiveHandoffRuntimeKernel"
                        , "nestedRecursiveHandoffRuntimeKernel"
                        , "withRecursiveHandoffRuntimeKernel"
                        , "withRootArmRecursiveHandoffRuntimeKernel"
                        , "withNestedArmRecursiveHandoffRuntimeKernel"
                        ]
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "withRootArmRecursiveHandoffRuntimeKernel"
                    , "withRootedFrameOpeningKernel"
                    , "withRootedOpenedResponseKernel"
                    , "RootedLifecycleService"
                    ]
                assertContains
                    "the root-arm fold discloses no authenticated frame, because a root has none"
                    "RootRecursiveHandoffRuntime verb project tag store generation keyDigest -> use project tag store generation (projectVerbName verb) keyDigest"
                    rootArm
                assertContains
                    "a keyless nested arm cannot be read as a root runtime at all"
                    "NestedRecursiveHandoffRuntime{} -> pure (Left (failure \"a keyless nested arm has no root recursive handoff runtime\"))"
                    rootArm
                assertFragmentsInOrder
                    "the opening binds the root arm, then the session, then admits before signing"
                    [ "withRootedFrameOpeningKernel runtime session store envelope request sign use = withRootArmRecursiveHandoffRuntimeKernel runtime"
                    , "withRootedFrameSessionKernel session"
                    , "case admit attached generation catalogIdentity path token stage ordinal of"
                    , "Left failure -> pure (Left failure)"
                    , "Right unsigned -> do"
                    , "signed <- sign unsigned"
                    ]
                    opening
                assertFragmentsInOrder
                    "the complete signed response is recorded and read back before the caller may release it"
                    [ "Right signedOpened -> withAttachedRootedFrameSessionKernel runtime session store envelope request signedOpened"
                    , "(\\opened -> use opened signedOpened)"
                    ]
                    opening
                assertFragmentsInOrder
                    "the envelope grammar is enforced before the envelope is compared to the session's own path"
                    [ "requireEnvelopeGrammar"
                    , "require \"the sealed external envelope is not the session's own path\" (envelope == path)"
                    , "rootedLifecycleRequestFromWireKernel request"
                    ]
                    opening
                assertContains
                    "the sealed ancestry uses the post-open one-to-256 component depth"
                    "require \"the sealed external envelope exceeds the requester path depth\" (length envelope <= maxRootedRequesterComponents)"
                    opening
                assertContains
                    "and the same 4,096-byte encoded component bound"
                    "require \"the sealed external envelope contains an oversized component\" ( all ( (<= maxRootedRequesterComponentBytes) . ByteString.length . TextEncoding.encodeUtf8 ) envelope )"
                    opening
                assertBool
                    "both bounds are the post-open request codec's own"
                    ( "maxRootedRequesterComponents = 256" `isInfixOf` normalizeWhitespace rootedSource
                        && "maxRootedRequesterComponentBytes = 4096"
                            `isInfixOf` normalizeWhitespace rootedSource
                    )
                assertContains
                    "an already attached session cannot answer a second opening"
                    "require \"an attached rooted frame session cannot answer a second opening\" (not attached)"
                    opening
                assertContains
                    "every post-open request form leaves through one fixed refusal"
                    "postOpenOpening = Left (rootedFailure \"only an OpenFrame request opens a rooted frame exchange\")"
                    opening
                assertContains
                    "the response names the request by digest and takes every other field from the session"
                    "rootedOpenedResponseUnsignedKernel (childConfigDigest request) path token stage ordinal"
                    opening
                assertFragmentsInOrder
                    "the call site binds the root arm and its installed key before the session is read"
                    [ "withRootedOpenedResponseKernel runtime broker session store envelope request use = withRootArmRecursiveHandoffRuntimeKernel runtime"
                    , "if keyDigest /= brokerRouteVerificationKeyDigest (rootBrokerRoute broker)"
                    , "then pure (Left (openingFailure \"the installed runtime key is not the live root broker's\"))"
                    , "else withRootedFrameOpeningKernel runtime session store envelope request sign use"
                    ]
                    callSite
                assertContains
                    "only the fixed signer under the hidden admission produces the response"
                    "sign unsigned = do signed <- signRootedLifecycleResponseKernel recoverySigningKernel broker request unsigned"
                    callSite
                assertContains
                    "the root arm now runs its live endpoint instead of refusing every request"
                    "linkRootedLifecycleRaw = \\path exactRequest -> case rootedRequestPath exactRequest >>= requireRootedRequesterPath True path of Left failure -> pure (Left failure) Right () -> serveRooted path exactRequest"
                    endpoint
                assertContains
                    "the endpoint shape is the link field's own, so a hop reads no more than before"
                    "RequesterPath -> ByteString -> IO (Either RelayError (Either (ByteString, ByteString) ByteString))"
                    service
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier rootedSource @?= 0)
                    [ "HandoffChannel"
                    , "BrokerLink"
                    , "transmit"
                    , "channelSend"
                    ]
                sites "withRootArmRecursiveHandoffRuntimeKernel"
                    @?= [ ("HostBootstrap.Handoff.Relay", 2)
                        , ("HostBootstrap.Handoff.Runtime", 4)
                        , ("HostBootstrap.Lifecycle.Rooted", 2)
                        ]
                sites "withRootedFrameOpeningKernel"
                    @?= [ ("HostBootstrap.Handoff.Relay", 2)
                        , ("HostBootstrap.Lifecycle.Rooted", 4)
                        ]
                sites "withRootedOpenedResponseKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 3)
                        , ("HostBootstrap.Handoff.Relay", 3)
                        ]
                sites "RootedLifecycleService"
                    @?= [("HostBootstrap.Handoff.Relay", 4)]
                assertBool
                    "the rooted-opening runtime stays inside its sprint line budget"
                    (significantHaskellLineCount runtimeSource < 400)
        , testCase "the storeless frame executor holds coordinates, never authority" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                executorSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "FrameExecutor.hs")
                gateSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Prepared" </> "Internal.hs")
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources sourceRoot
                librarySource <-
                    maybe
                        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                        pure
                        (mainLibraryStanza cabalSource)
                executorExports <-
                    requiredModuleExports "HostBootstrap.Lifecycle.FrameExecutor" executorSource
                openingSource <-
                    requiredSourceSection
                        "the frame executor opening"
                        "withOpenedFrameExecutorKernel ::"
                        "{- | Build this frame's next request"
                        executorSource
                requestSource <-
                    requiredSourceSection
                        "the frame executor request builder"
                        "withFrameExecutorRequestKernel ::"
                        "{- | Advance to the successor the verified response selected."
                        executorSource
                advanceSource <-
                    requiredSourceSection
                        "the frame executor advance"
                        "withAdvancedFrameExecutorKernel ::"
                        "{- | Run one node's local effect"
                        executorSource
                executionSource <-
                    requiredSourceSection
                        "the frame executor local execution"
                        "withExecutedFrameNodeKernel ::"
                        "{- | Turn signed bytes into a response"
                        executorSource
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                let executor = normalizeWhitespace executorSource
                    opening = normalizeWhitespace openingSource
                    request = normalizeWhitespace requestSource
                    advance = normalizeWhitespace advanceSource
                    execution = normalizeWhitespace executionSource
                    exposed = fieldModules "exposed-modules:" librarySource
                    privateModules = fieldModules "other-modules:" librarySource
                    importers moduleName =
                        sort
                            [ importer
                            | (importer, _path, source) <- sources
                            , SourceGuard.importsModule moduleName source
                            ]
                    sites name =
                        [ (moduleName, count)
                        | (moduleName, _path, sourceBody) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name sourceBody
                        , count > 0
                        ]
                filter (/= ",") executorExports
                    @?= [ "FrameExecutor"
                        , "withOpenedFrameExecutorKernel"
                        , "withOpenedFrameExecutorForPlanKernel"
                        , "withFrameExecutorRequestKernel"
                        , "withAdvancedFrameExecutorKernel"
                        , "withExecutedFrameNodeKernel"
                        ]
                assertBool
                    "the frame executor stays Cabal-private"
                    ( "HostBootstrap.Lifecycle.FrameExecutor" `notElem` exposed
                        && length (filter (== "HostBootstrap.Lifecycle.FrameExecutor") privateModules) == 1
                    )
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "FrameExecutor"
                    , "withOpenedFrameExecutorKernel"
                    , "withOpenedFrameExecutorForPlanKernel"
                    , "withFrameExecutorRequestKernel"
                    , "withAdvancedFrameExecutorKernel"
                    , "withExecutedFrameNodeKernel"
                    ]
                assertContains
                    "the sole named type carries seven nominal roles"
                    "type role FrameExecutor nominal nominal nominal nominal nominal nominal nominal"
                    executor
                SourceGuard.countHaskellIdentifier "data" executorSource @?= 1
                SourceGuard.countHaskellIdentifier "newtype" executorSource @?= 0
                assertContains
                    "five of the seven indices are minted by the opening rather than chosen"
                    "( forall rootPlanId brokerGeneration catalogId frame sessionId. FrameExecutor scope rootPlanId brokerGeneration catalogId frame sessionId verb -> IO (Either Text ()) ) -> IO (Either Text ())"
                    opening
                assertFragmentsInOrder
                    "the frame's own nodes are checked, then the Opened response is verified, then the coordinates are taken"
                    [ "require \"a supplied execution node belongs to another frame\" (all ((== frameName) . executionNodeFrame) nodes)"
                    , "require \"the frame plan carries one operation key twice\" (length keys == length (nub keys))"
                    , "verified <- verifiedResponse key request signedOpened"
                    , "(\\_ path session stage ordinal _ -> Right (path, session, stage, ordinal))"
                    ]
                    opening
                assertContains
                    "no other response family opens an executor"
                    "beforeOpened = Left (executorFailure \"only a verified Opened response opens a frame executor\")"
                    opening
                assertContains
                    "the first predecessor is the digest of the complete signed Opened bytes"
                    "(childConfigDigest signedOpened)"
                    opening
                assertFragmentsInOrder
                    "every request echoes the executor's own retained coordinates"
                    [ "FrameExecutor _ _ _ _ _ _ path session stage ordinal predecessor = executor"
                    , "rootedNextNodeRequestKernel path session stage ordinal nonce predecessor"
                    , "rootedCloseFrameRequestKernel path session stage ordinal nonce predecessor"
                    , "rootedReceiptConfirmRequestKernel path session stage ordinal nonce predecessor"
                    , "rootedDescendResultRequestKernel path session stage ordinal nonce predecessor observation"
                    , "rootedSettleNodeRequestKernel path session stage ordinal nonce predecessor observation"
                    ]
                    request
                assertContains
                    "the five families are closed and an OpenFrame is not among them"
                    "a frame executor raises no request outside its five families"
                    request
                assertBool
                    "no executor path constructs an opening request"
                    (SourceGuard.countHaskellIdentifier "rootedOpenFrameRequestKernel" executorSource == 0)
                assertFragmentsInOrder
                    "advancing verifies first, then copies the root-selected successor"
                    [ "verified <- verifiedResponse key request signedResponse"
                    , "require \"the verified response echoes another requester path\" (responsePath == path)"
                    , "require \"the verified response echoes another session\" (responseSession == session)"
                    , "require \"the verified response does not select a successor ordinal\" (successorOrdinal > ordinal)"
                    , "(childConfigDigest signedResponse)"
                    ]
                    advance
                assertContains
                    "an Opened response cannot advance an already opened executor"
                    "afterOpened = Left (executorFailure \"an Opened response cannot advance an opened frame executor\")"
                    advance
                assertFragmentsInOrder
                    "execution admits, then runs, and only a nonempty observation escapes"
                    [ "case admit of"
                    , "Left failure -> pure (Left failure)"
                    , "Right (node, gate, projected) -> do"
                    , "observed <- run node gate projected carrier"
                    , "ByteString.null observation"
                    , "otherwise -> use observation"
                    ]
                    execution
                assertFragmentsInOrder
                    "the four packages are read out of a verified Prepared answer, never supplied beside it"
                    [ "verified <- verifiedResponse key request signedPrepared"
                    , "(\\_ p s _ _ _ n d o g _ -> Right (p, s, n, d, o, g))"
                    , "require \"the Prepared response echoes another requester path\" (responsePath == path)"
                    , "require \"the Prepared response echoes another session\" (responseSession == session)"
                    ]
                    execution
                assertContains
                    "no other response family authorizes a local effect"
                    "outsidePrepared = Left (executorFailure \"only a verified Prepared response authorizes a local effect\")"
                    execution
                assertFragmentsInOrder
                    "the authorized node, its dependencies, and its projections are all compared before any gate is minted"
                    [ "find ((== authorized) . TextEncoding.encodeUtf8 . executionNodeOperationKey) nodes"
                    , "require \"the authorized dependencies are not this node's own\" (dependencies == renderPreparedNodeKeysKernel (executionNodeDependencyKeys node))"
                    , "packages <- readPreparedGatePackagesKernel projectedGates"
                    , "require \"the projected gate list is not the canonical one it carries\" (renderPreparedGatePackagesKernel packages == projectedGates)"
                    , "require \"the projected gates are not this node's own projections\" (length packages == length (executionNodeProjectedKeys node))"
                    , "gate <- gateFor (executionNodeOperationKey node) operationGate"
                    , "projected <- traverse (uncurry gateFor) (zip (executionNodeProjectedKeys node) packages)"
                    ]
                    execution
                assertFragmentsInOrder
                    "each gate package must name this plan, frame, and session before it becomes a local gate"
                    [ "readPreparedGatePackageKernel package"
                    , "require \"a gate package names another plan\" (packagePlan == planDigest)"
                    , "require \"a gate package names another frame\" (packageFrame == frameName)"
                    , "require \"a gate package names another session\" (packageSession == session)"
                    , "pure (mintPreparedGate packagePlan operation packageSession generation attempt journalVersion)"
                    ]
                    execution
                assertContains
                    "one helper is the only route from signed bytes to a response"
                    "verifiedResponse key request signed = either (Left . executorFailure . Text.pack . handoffErrorMessage) Right (withVerifiedRootedLifecycleResponse key request signed id)"
                    executor
                assertContains
                    "the gate package decode is canonical rather than merely well shaped"
                    "\"is not a canonical gate package\""
                    (normalizeWhitespace gateSource)
                assertContains
                    "the gate list count is checked rather than trusted"
                    "\"does not carry the number of gate packages it declares\""
                    (normalizeWhitespace gateSource)
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier executorSource @?= 0)
                    [ "ProtectedStore"
                    , "ProtectedSession"
                    , "RecordKey"
                    , "withProtectedEntry"
                    , "compareAndSwapProtectedRecord"
                    , "RootBroker"
                    , "ProjectSigningKey"
                    , "recoverySigningKernel"
                    , "signRootedLifecycleResponseKernel"
                    , "RootedPlanCatalog"
                    , "RootedFrameSession"
                    , "withRootOpenedFrameSessionKernel"
                    , "createProcess"
                    , "unsafeCoerce"
                    ]
                mapM_
                    ( \moduleName ->
                        assertBool
                            ("the frame executor imports no store or root owner " <> moduleName)
                            (not (SourceGuard.importsModule moduleName executorSource))
                    )
                    [ "HostBootstrap.Chain"
                    , "HostBootstrap.Command"
                    , "HostBootstrap.Command.LifecycleEntry"
                    , "HostBootstrap.Handoff.Protocol"
                    , "HostBootstrap.Handoff.Receiver"
                    , "HostBootstrap.Handoff.Relay"
                    , "HostBootstrap.Lifecycle.Rooted"
                    , "HostBootstrap.Lifecycle.RootedPlan"
                    , "HostBootstrap.Lifecycle.Session"
                    , "HostBootstrap.Protected"
                    , "System.Process"
                    ]
                importers "HostBootstrap.Lifecycle.FrameExecutor"
                    @?= ["HostBootstrap.Command.Child"]
                sites "withOpenedFrameExecutorKernel"
                    @?= [ ("HostBootstrap.Command.Child", 2)
                        , ("HostBootstrap.Lifecycle.FrameExecutor", 4)
                        ]
                sites "withOpenedFrameExecutorForPlanKernel"
                    @?= [ ("HostBootstrap.Command.Child", 2)
                        , ("HostBootstrap.Lifecycle.FrameExecutor", 4)
                        ]
                sites "readPreparedGatePackageKernel"
                    @?= [ ("HostBootstrap.Lifecycle.FrameExecutor", 2)
                        , ("HostBootstrap.Lifecycle.Prepared.Internal", 3)
                        ]
                sites "renderPreparedNodeKeysKernel"
                    @?= [ ("HostBootstrap.Handoff.Relay", 2)
                        , ("HostBootstrap.Lifecycle.FrameExecutor", 2)
                        , ("HostBootstrap.Lifecycle.Prepared.Internal", 3)
                        ]
                assertBool
                    "the executor and the gate owner stay inside their sprint line budgets"
                    ( significantHaskellLineCount executorSource < 400
                        && significantHaskellLineCount gateSource < 400
                    )
        , testCase "the forward child owns one authenticated storeless conversation" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                childSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Command" </> "Child.hs")
                routeSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Process" </> "Route.hs")
                cliSource <- readFile (sourceRoot </> "HostBootstrap" </> "CLI.hs")
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources sourceRoot
                librarySource <-
                    maybe
                        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                        pure
                        (mainLibraryStanza cabalSource)
                childExports <- requiredModuleExports "HostBootstrap.Command.Child" childSource
                activationExtension <-
                    requiredSourceSection
                        "worked-demo activation relay extension"
                        "activationRuntime <- newStepRuntime carrier"
                        "let opened = openWith carrier runtime link nonce"
                        childSource
                let child = normalizeWhitespace childSource
                    exposed = fieldModules "exposed-modules:" librarySource
                    privateModules = fieldModules "other-modules:" librarySource
                    importers moduleName =
                        sort
                            [ importer
                            | (importer, _path, source) <- sources
                            , SourceGuard.importsModule moduleName source
                            ]
                filter (/= ",") childExports
                    @?= ["lifecycleChildArguments", "runForwardLifecycleChild"]
                assertBool
                    "the lifecycle child stays Cabal-private"
                    ( "HostBootstrap.Command.Child" `notElem` exposed
                        && length (filter (== "HostBootstrap.Command.Child") privateModules) == 1
                    )
                importers "HostBootstrap.Command.Child" @?= ["HostBootstrap.CLI"]
                assertContains
                    "the route and receiver share one fixed coordinate-free marker"
                    "subcommand _verb = [\"--hostbootstrap-lifecycle-child\"]"
                    (normalizeWhitespace routeSource)
                assertContains
                    "the entry itself accepts no descriptive coordinate"
                    "lifecycleChildArguments = [\"--hostbootstrap-lifecycle-child\"]"
                    child
                assertFragmentsInOrder
                    "scope and config are authenticated before the plan and executor exist"
                    [ "withIsolatedReceivedHandoffEdge project key"
                    , "withAuthenticatedConfigWire (finalizedProjectCodec finalized) authenticated"
                    , "withVerifiedConfigHandoff ProjectUp (receivedEdgeHandoff edge) wire config"
                    , "withChildProjectPlan ProjectUp handoff wire config drafts"
                    , "carrier <- newResourceCarrier"
                    , "withOpenedFrameExecutorForPlanKernel key (receivedEdgeAuthenticatedRootScope edge) ProjectUp"
                    ]
                    child
                assertFragmentsInOrder
                    "a prepared node executes, settles, and advances through signed responses"
                    [ "withExecutedFrameNodeKernel executor key exactRequest signed"
                    , "withAdvancedFrameExecutorKernel executor key exactRequest signed"
                    , "sendExecutorRequest prepared \"settle-node\" (Just observation)"
                    , "withAdvancedFrameExecutorKernel prepared key settleRequest settled"
                    ]
                    child
                assertFragmentsInOrder
                    "terminal reporting follows close and receipt confirmation"
                    [ "sendExecutorRequest executor \"close-frame\" Nothing"
                    , "sendExecutorRequest completedFrame \"receipt-confirm\" Nothing"
                    , "sendReport report"
                    ]
                    child
                assertContains
                    "descent launches only its immediate projected child and reports the closed result"
                    "withImmediateTargetKernel finalized plan current"
                    child
                assertContains
                    "the nested process uses the keyless link and sanitized immediate route"
                    "withNestedForwardLifecycleProcessRouteKernel runtime route input ProjectUp"
                    child
                assertContains
                    "the descendant observation is closed"
                    "frameWire \"hostbootstrap/forward-descent-result/v1\" <> frameWire \"succeeded\""
                    child
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier childSource @?= 0)
                    [ "ProtectedStore"
                    , "ProtectedSession"
                    , "RootBroker"
                    , "ProjectSigningKey"
                    , "withRootBroker"
                    , "withProtectedEntry"
                    , "compareAndSwapProtectedRecord"
                    , "createProcess"
                    , "unsafeCoerce"
                    ]
                assertBool
                    "the child owner remains within two coherent sprint splits"
                    ( significantHaskellLineCount childSource
                        - significantHaskellLineCount activationExtension
                        - 8
                        - 5
                        + SourceGuard.countHaskellIdentifier "runForwardLifecycleChild" cliSource
                        < 800
                    )
        , testCase "the protocol-safe process route sanitizes its launch and orders its opening" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                routeSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Process" </> "Route.hs")
                runtimeSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Runtime.hs")
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources sourceRoot
                librarySource <-
                    maybe
                        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                        pure
                        (mainLibraryStanza cabalSource)
                routeExports <-
                    requiredModuleExports "HostBootstrap.Handoff.Process.Route" routeSource
                derivationSource <-
                    requiredSourceSection
                        "the process route derivation"
                        "withForwardLifecycleProcessRouteKernel ::"
                        "{- | Render exactly one argv shape"
                        routeSource
                launchSource <-
                    requiredSourceSection
                        "the process route launch grammar"
                        "sanitizedLaunch :: LiftContext"
                        "{- | Borrow the launch this route renders"
                        routeSource
                openingSource <-
                    requiredSourceSection
                        "the lifecycle child opening"
                        "withLifecycleChildOpeningKernel ::"
                        "-- | Turn signed bytes into a response"
                        routeSource
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                let route = normalizeWhitespace routeSource
                    runtime = normalizeWhitespace runtimeSource
                    derivation = normalizeWhitespace derivationSource
                    launch = normalizeWhitespace launchSource
                    opening = normalizeWhitespace openingSource
                    exposed = fieldModules "exposed-modules:" librarySource
                    privateModules = fieldModules "other-modules:" librarySource
                    importers moduleName =
                        sort
                            [ importer
                            | (importer, _path, source) <- sources
                            , SourceGuard.importsModule moduleName source
                            ]
                filter (/= ",") routeExports
                    @?= [ "LifecycleProcessRoute"
                        , "withForwardLifecycleProcessRouteKernel"
                        , "withNestedForwardLifecycleProcessRouteKernel"
                        , "withRecoveryLifecycleProcessRouteKernel"
                        , "withRecoveryLifecycleProcessRouteForKernel"
                        , "withLifecycleProcessRouteLaunchKernel"
                        , "withLifecycleChildOpeningKernel"
                        ]
                assertBool
                    "the process route stays Cabal-private"
                    ( "HostBootstrap.Handoff.Process.Route" `notElem` exposed
                        && length
                            (filter (== "HostBootstrap.Handoff.Process.Route") privateModules)
                            == 1
                    )
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "LifecycleProcessRoute"
                    , "withForwardLifecycleProcessRouteKernel"
                    , "withRecoveryLifecycleProcessRouteKernel"
                    , "withLifecycleProcessRouteLaunchKernel"
                    , "withLifecycleChildOpeningKernel"
                    ]
                assertContains
                    "the sole named type carries seven nominal roles"
                    "type role LifecycleProcessRoute nominal nominal nominal nominal nominal nominal nominal"
                    route
                SourceGuard.countHaskellIdentifier "data" routeSource @?= 1
                SourceGuard.countHaskellIdentifier "newtype" routeSource @?= 0
                assertContains
                    "the edge is minted by a derivation rather than named"
                    "( forall parent child. LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb -> IO (Either Text ()) ) -> IO (Either Text ())"
                    derivation
                assertFragmentsInOrder
                    "both routes are derived from a package rather than assembled from arguments"
                    [ "withCatalogForwardProcessInputsKernel package $ \\route input _payload ->"
                    , "case derive verb \"execute\" (withoutConfigDelivery route) input targetBinary of"
                    , "use (LifecycleProcessRoute verb parent child tool argv interactive)"
                    , "derive verb \"teardown\" (withoutConfigDelivery route) input targetBinary"
                    ]
                    derivation
                assertFragmentsInOrder
                    "the edge is the binding input's own and its phase is checked before a launch is rendered"
                    [ "require \"the admitted edge joins one frame to itself\" (parent /= child)"
                    , "(requestedPhase input == phase)"
                    , "(tool, argv, interactive) <- sanitizedLaunch route child targetBinary (subcommand verb)"
                    , "parent = requestedParentFrame input"
                    , "child = requestedChildFrame input"
                    ]
                    derivation
                assertContains
                    "the child's command is the coordinate-free lifecycle entry marker"
                    "subcommand _verb = [\"--hostbootstrap-lifecycle-child\"]"
                    derivation
                assertFragmentsInOrder
                    "a container is refused its delivery, its extra arguments, and its survival before an argv exists"
                    [ "\"a container layer needs no target binary path\" (Text.null targetBinary)"
                    , "\"the admitted container layer delivers a configuration on standard input\" (isNothing (clConfigDelivery container))"
                    , "\"the admitted container layer carries plan-authored extra arguments\" (null (clExtraArgs container))"
                    , "\"the admitted container layer outlives its own exchange\" (clRemoveAfter container)"
                    ]
                    launch
                assertFragmentsInOrder
                    "the route validates policy and delegates every crossing argv to the sole Lift fold"
                    [ "admitted <- admittedContainer child container"
                    , "folded (LiftContext [ViaContainer admitted]) \"\" inner True"
                    , "folded route targetBinary inner False"
                    , "(admitted, interactive) <- validateComposedLayers child layers targetBinary"
                    , "folded (LiftContext admitted) targetBinary inner interactive"
                    , "HOSTBOOTSTRAP_DIRECT_CONTAINER=linux-gpu"
                    , "HOSTBOOTSTRAP_CURRENT_FRAME=\" <> Text.unpack frame"
                    , "++ placementArgs"
                    , "case foldLeaf route (lifecycleProcessLeaf"
                    , "DispatchTool tool argv -> Right"
                    ]
                    launch
                assertFragmentsInOrder
                    "a composed terminal container receives the same admitted protocol-channel arguments"
                    [ "go [ViaContainer container] = do"
                    , "admitted <- admittedContainer child container"
                    , "pure ([ViaContainer admitted], True)"
                    , "admittedContainer child container = do"
                    , "\"-i\""
                    , "\"--network=host\""
                    , "HOSTBOOTSTRAP_CURRENT_FRAME="
                    , "HOSTBOOTSTRAP_REGISTRY_AUTH"
                    , "[\"-w\", \"/\"]"
                    ]
                    launch
                mapM_
                    (\fragment -> assertBool ("route duplicated crossing argv: " <> fragment) (fragment `notElem` words routeSource))
                    ["\"exec\"", "\"shell\""]
                assertContains
                    "a route that is not exactly one plan-owned layer renders nothing"
                    "a process route carries exactly one plan-owned lift layer"
                    launch
                assertContains
                    "the closed grammar names the overrides it refuses rather than escaping them"
                    "rejectedOverrides = [ \"--\" , \"--attach\" , \"--detach\" , \"--entrypoint\" , \"--interactive\" , \"--preserve-fds\" , \"--sig-proxy\" , \"--stop-signal\" , \"--tty\" , \"--workdir\" ]"
                    route
                assertContains
                    "every derived argument is admitted against that grammar"
                    "require (label <> \" reads as an option or a separator\") (not (\"-\" `Text.isPrefixOf` value))"
                    route
                assertFragmentsInOrder
                    "a frame opens for itself: its own nested arm carries an OpenFrame built from the nonce alone, and the answer is verified against those exact bytes"
                    [ "withNestedArmRecursiveHandoffRuntimeKernel runtime $ \\_ _ _ _ _ _ admittedFrame ->"
                    , "answered <- carry request"
                    , "request <- either (Left . routeFailure) Right (rootedOpenFrameRequestKernel nonce)"
                    , "verified <- verifiedResponse key request signedOpened"
                    , "(\\_ _ _ _ _ _ -> Right signedOpened)"
                    ]
                    opening
                assertContains
                    "no other response family opens a child frame"
                    "beforeOpened = Left (routeFailure \"only a verified Opened response opens a lifecycle child frame\")"
                    opening
                assertContains
                    "what leaves is the exact request and the exact signed answer, never a decoded coordinate"
                    "Right signedOpened -> use request signedOpened"
                    opening
                assertBool
                    "the route owns no post-open coordinate, because the frame executor does"
                    ( SourceGuard.countHaskellIdentifier "rootedNextNodeRequestKernel" routeSource == 0
                        && SourceGuard.countHaskellIdentifier "rootedSettleNodeRequestKernel" routeSource == 0
                        && SourceGuard.countHaskellIdentifier "rootedCloseFrameRequestKernel" routeSource == 0
                        && SourceGuard.countHaskellIdentifier "rootedReceiptConfirmRequestKernel" routeSource == 0
                    )
                assertContains
                    "one helper is the only route from signed bytes to a response"
                    "verifiedResponse key request signed = either (Left . routeFailure . Text.pack . handoffErrorMessage) Right (withVerifiedRootedLifecycleResponse key request signed id)"
                    route
                assertContains
                    "the nested-arm fold refuses the root arm rather than describing it"
                    "RootRecursiveHandoffRuntime{} -> pure (Left (failure \"a root arm speaks for no authenticated nested frame\"))"
                    runtime
                assertContains
                    "the nested-arm fold discloses the authenticated frame itself rather than a Maybe"
                    "NestedRecursiveHandoffRuntime verb project tag store generation keyDigest frame -> use project tag store generation (projectVerbName verb) keyDigest frame"
                    runtime
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier routeSource @?= 0)
                    [ "ProtectedStore"
                    , "ProtectedSession"
                    , "RecordKey"
                    , "RootBroker"
                    , "ProjectSigningKey"
                    , "RootedPlanCatalog"
                    , "RootedFrameSession"
                    , "FrameExecutor"
                    , "createProcess"
                    , "spawnProcess"
                    , "ProcessHandle"
                    , "waitForProcess"
                    , "hDuplicate"
                    , "unsafeCoerce"
                    ]
                assertBool
                    "the route derives its crossing through the lower Lift fold"
                    (SourceGuard.importsModule "HostBootstrap.Lift" routeSource)
                mapM_
                    ( \moduleName ->
                        assertBool
                            ("the process route imports no owner or channel " <> moduleName)
                            (not (SourceGuard.importsModule moduleName routeSource))
                    )
                    [ "HostBootstrap.Chain"
                    , "HostBootstrap.Command"
                    , "HostBootstrap.Command.LifecycleEntry"
                    , "HostBootstrap.Ensure"
                    , "HostBootstrap.Handoff.Protocol"
                    , "HostBootstrap.Handoff.Receiver"
                    , "HostBootstrap.Handoff.Relay"
                    , "HostBootstrap.Lifecycle.FrameExecutor"
                    , "HostBootstrap.Lifecycle.Rooted"
                    , "HostBootstrap.Lifecycle.RootedPlan"
                    , "HostBootstrap.Lifecycle.Session"
                    , "HostBootstrap.Protected"
                    , "HostBootstrap.Teardown.Internal"
                    , "System.IO"
                    , "System.Process"
                    ]
                importers "HostBootstrap.Handoff.Process.Route"
                    @?= [ "HostBootstrap.Command.Child"
                        , "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.Handoff.Process"
                        ]
                assertBool
                    "the process route and the runtime stay inside their sprint line budgets"
                    ( significantHaskellLineCount routeSource < 400
                        && significantHaskellLineCount runtimeSource < 400
                    )
        , testCase "the prepared node grant follows exact durable unknown rows and mints nothing else" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                gateSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Prepared" </> "Internal.hs")
                rootedSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Rooted" </> "Node.hs")
                sessionOwnerSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Rooted.hs")
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources sourceRoot
                librarySource <-
                    maybe
                        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                        pure
                        (mainLibraryStanza cabalSource)
                gateExports <-
                    requiredModuleExports "HostBootstrap.Lifecycle.Prepared.Internal" gateSource
                nodeExports <-
                    requiredModuleExports "HostBootstrap.Lifecycle.Rooted.Node" rootedSource
                producerSource <-
                    requiredSourceSection
                        "the durable node-grant producer"
                        "withPreparedRootedNodeGrantKernel ::"
                        "{- | Settle one executor observation exactly once"
                        rootedSource
                settlementSource <-
                    requiredSourceSection
                        "the durable node settlement"
                        "withSettledRootedNodeKernel ::"
                        "{- | Publish one exact row and read it back"
                        rootedSource
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                let gate = normalizeWhitespace gateSource
                    producer = normalizeWhitespace producerSource
                    settlement = normalizeWhitespace settlementSource
                    exposed = fieldModules "exposed-modules:" librarySource
                    privateModules = fieldModules "other-modules:" librarySource
                    sites name =
                        [ (moduleName, count)
                        | (moduleName, _path, sourceBody) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name sourceBody
                        , count > 0
                        ]
                filter (/= ",") gateExports
                    @?= [ "PreparedGate"
                        , "preparedGatePlan"
                        , "preparedGateOperation"
                        , "preparedGateSession"
                        , "preparedGateFence"
                        , "preparedGateAttempt"
                        , "preparedGateJournalVersion"
                        , "mintPreparedGate"
                        , "PreparedNodeGrant"
                        , "renderPreparedGatePackageKernel"
                        , "renderPreparedGatePackagesKernel"
                        , "readPreparedGatePackageKernel"
                        , "readPreparedGatePackagesKernel"
                        , "renderPreparedNodeKeysKernel"
                        , "mintPreparedNodeGrantKernel"
                        , "withPreparedNodeGrantKernel"
                        ]
                assertBool
                    "the gate owner stays Cabal-private"
                    ( "HostBootstrap.Lifecycle.Prepared.Internal" `notElem` exposed
                        && length (filter (== "HostBootstrap.Lifecycle.Prepared.Internal") privateModules) == 1
                    )
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "PreparedNodeGrant"
                    , "mintPreparedNodeGrantKernel"
                    , "withPreparedNodeGrantKernel"
                    , "withPreparedRootedNodeGrantKernel"
                    ]
                assertContains
                    "the grant carries eight nominal roles"
                    "type role PreparedNodeGrant nominal nominal nominal nominal nominal nominal nominal nominal"
                    gate
                assertContains
                    "the grant retains node, dependencies, and both gate packages only"
                    "PreparedNodeGrant :: Text -> [Text] -> ByteString -> ByteString -> PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb"
                    gate
                assertContains
                    "the gate package frames every coordinate canonically with an explicit version"
                    "framed \"hostbootstrap/prepared-node-gate\" , framedWord 1 , framed planDigest , framed catalogIdentity , framed frame , framed session , framedWord generation , framedWord attempt , framedWord journalVersion"
                    gate
                assertContains
                    "the projected gate list carries an explicit count"
                    "[framed \"hostbootstrap/prepared-node-gates\", framedWord 1, framedWord (fromIntegral (length packages))] ++ map frame' packages"
                    gate
                assertContains
                    "the evidence fold is fixed-unit and exposes no durable state"
                    "withPreparedNodeGrantKernel :: PreparedNodeGrant scope rootPlanId brokerGeneration catalogId frame sessionId node verb -> (Text -> [Text] -> ByteString -> ByteString -> IO (Either Text ())) -> IO (Either Text ())"
                    gate
                assertFragmentsInOrder
                    "admission gates the ordered publication, and an unattached session is refused inside it"
                    [ "case admit attached atRoot current of"
                    , "Left failure -> pure (Left failure)"
                    , "publishOrdered lineage localPlanDigest catalogIdentity frame token ordinal (node : projectedOperations) []"
                    , "Right (own : projected) -> use ( mintPreparedNodeGrantKernel node dependencies own (renderPreparedGatePackagesKernel projected) )"
                    ]
                    producer
                assertFragmentsInOrder
                    "each row is keyed, published, and gate-packaged before the next"
                    [ "rootedNodeUnknownKeyKernel lineage catalogIdentity frame operation"
                    , "published <- publishExactRow store \"unknown\" key unknown"
                    , "renderPreparedGatePackageKernel"
                    ]
                    producer
                assertFragmentsInOrder
                    "the shared publisher strictly reads back and byte-checks every row it writes"
                    [ "publishRootedUnknownRowKernel protected key expected"
                    , "present /= expected"
                    , "is not this preparation"
                    , "Right (recordVersionWord version)"
                    ]
                    (normalizeWhitespace rootedSource)
                assertContains
                    "the node's own operation is prepared before its projected operations"
                    "(node : projectedOperations)"
                    producer
                assertContains
                    "the projected operation order refuses duplicates"
                    "length projectedOperations == length (nub projectedOperations)"
                    producer
                assertContains
                    "an unattached session cannot prepare a grant"
                    "require \"an unattached rooted frame session cannot prepare a node grant\" attached"
                    producer
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier rootedSource @?= 0)
                    [ "rootedDescendResponseUnsignedKernel"
                    , "rootedPreparedResponseUnsignedKernel"
                    , "mintPreparedGate"
                    ]
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier gateSource @?= 0)
                    [ "ProtectedStore"
                    , "ProtectedSession"
                    , "RecordKey"
                    , "compareAndSwapProtectedRecord"
                    , "withProtectedEntry"
                    , "RootedPlanCatalog"
                    ]
                sites "mintPreparedGate"
                    @?= [ ("HostBootstrap.Lifecycle.FrameExecutor", 2)
                        , ("HostBootstrap.Lifecycle.Prepared.Internal", 3)
                        , ("HostBootstrap.Lifecycle.Prepared", 2)
                        , ("HostBootstrap.Lifecycle.Session", 2)
                        ]
                sites "mintPreparedNodeGrantKernel"
                    @?= [ ("HostBootstrap.Lifecycle.Prepared.Internal", 3)
                        , ("HostBootstrap.Lifecycle.Rooted.Node", 2)
                        ]
                sites "publishRootedUnknownRowKernel"
                    @?= [ ("HostBootstrap.Lifecycle.Rooted.Node", 2)
                        , ("HostBootstrap.Lifecycle.Session", 3)
                        ]
                filter (/= ",") nodeExports
                    @?= [ "withPreparedRootedNodeGrantKernel"
                        , "withSettledRootedNodeKernel"
                        ]
                assertBool
                    "the node owner reaches a session only through its coordinate fold"
                    ( SourceGuard.countHaskellIdentifier "OpenedRootedFrameSession" rootedSource == 0
                        && SourceGuard.countHaskellIdentifier "AttachedRootedFrameSession" rootedSource == 0
                        && SourceGuard.countHaskellIdentifier "rootedFrameSessionKeyKernel" rootedSource == 0
                        && SourceGuard.countHaskellIdentifier "attachRootedFrameSessionRecordKernel" rootedSource == 0
                    )
                assertBool
                    "the session owner no longer names the node grant it split out"
                    ( SourceGuard.countHaskellIdentifier "PreparedNodeGrant" sessionOwnerSource == 0
                        && SourceGuard.countHaskellIdentifier "withPreparedRootedNodeGrantKernel" sessionOwnerSource == 0
                    )
                assertFragmentsInOrder
                    "settlement checks every echoed coordinate against the session before the durable row"
                    [ "require \"an unattached rooted frame session cannot settle a node\" attached"
                    , "require \"the session has no recorded predecessor\" (isJust predecessor)"
                    , "rootedLifecycleRequestFromWireKernel request"
                    , "require \"the settle request echoes another requester path\" (requestPath == path)"
                    , "require \"the settle request echoes another session\" (requestSession == token)"
                    , "require \"the settle request echoes another ordinal\" (requestOrdinal == ordinal)"
                    , "require \"the settle request echoes another predecessor\" (Just requestPredecessor == predecessor)"
                    , "rootedLifecycleResponseFromWireKernel signedSettled"
                    , "require \"the signed response does not select a successor ordinal\" (responseOrdinal > ordinal)"
                    ]
                    settlement
                assertContains
                    "only SettleNode and DescendResult settle, and every other request form refuses"
                    "outsideSettlement = Left (nodeFailure \"only a SettleNode or DescendResult request settles a rooted node\")"
                    settlement
                assertContains
                    "only the paired Settled or Refused response family settles"
                    "outsideSettlementFamily = Left (nodeFailure \"only a paired Settled or Refused response settles a rooted node\")"
                    settlement
                assertFragmentsInOrder
                    "the observation row is published and read back before the response digest is taken"
                    [ "rootedSettlementKeyKernel lineage catalogIdentity frame node ordinal"
                    , "published <- publishExactRow store \"settlement\" key settled"
                    , "Right _ -> use (childConfigDigest signedSettled)"
                    ]
                    settlement
                assertContains
                    "the settlement row is keyed by ordinal, so one node settled twice cannot overwrite itself"
                    "framedText settledNode , framedWord ordinal , frameWire observation"
                    settlement
                assertBool
                    "settlement mints no child gate or local execution authority"
                    ( SourceGuard.countHaskellIdentifier "mintPreparedGate" rootedSource == 0
                        && SourceGuard.countHaskellIdentifier "PreparedGate" rootedSource == 0
                    )
                sites "rootedSettlementKeyKernel"
                    @?= [ ("HostBootstrap.Lifecycle.Rooted.Node", 2)
                        , ("HostBootstrap.Lifecycle.Session", 3)
                        ]
                assertBool
                    "the prepared-grant split owners stay well inside the 400-line boundary"
                    ( significantHaskellLineCount gateSource < 400
                        && significantHaskellLineCount rootedSource < 400
                    )
        , testCase "the terminal receipt owner joins session, report, and receipt without a store" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                receiptSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Rooted" </> "Receipt.hs")
                sessionOwnerSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Rooted.hs")
                nodeOwnerSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Rooted" </> "Node.hs")
                relaySource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Handoff" </> "Relay.hs")
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources sourceRoot
                librarySource <-
                    maybe
                        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                        pure
                        (mainLibraryStanza cabalSource)
                receiptExports <-
                    requiredModuleExports "HostBootstrap.Lifecycle.Rooted.Receipt" receiptSource
                reportSource <-
                    requiredSourceSection
                        "the terminal report"
                        "withRootedTerminalReportKernel ::"
                        "{- | Confirm one terminal receipt against the exact report"
                        receiptSource
                confirmSource <-
                    requiredSourceSection
                        "the receipt confirmation"
                        "withRootedReceiptConfirmationKernel ::"
                        "{- | Admit one attached session's terminal coordinates"
                        receiptSource
                callSiteSource <-
                    requiredSourceSection
                        "the terminal receipt call site"
                        "withRootedTerminalReceiptKernel ::"
                        "{- | Ask this frame's route to sign one activation manifest."
                        relaySource
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                let report = normalizeWhitespace reportSource
                    confirm = normalizeWhitespace confirmSource
                    callSite = normalizeWhitespace callSiteSource
                    exposed = fieldModules "exposed-modules:" librarySource
                    privateModules = fieldModules "other-modules:" librarySource
                    importers moduleName =
                        sort
                            [ importer
                            | (importer, _path, source) <- sources
                            , SourceGuard.importsModule moduleName source
                            ]
                    sites name =
                        [ (moduleName, count)
                        | (moduleName, _path, sourceBody) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name sourceBody
                        , count > 0
                        ]
                filter (/= ",") receiptExports
                    @?= [ "withRootedTerminalReportKernel"
                        , "withRootedReceiptConfirmationKernel"
                        ]
                assertBool
                    "the terminal receipt owner stays Cabal-private"
                    ( "HostBootstrap.Lifecycle.Rooted.Receipt" `notElem` exposed
                        && length (filter (== "HostBootstrap.Lifecycle.Rooted.Receipt") privateModules) == 1
                    )
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "withRootedTerminalReportKernel"
                    , "withRootedReceiptConfirmationKernel"
                    , "withRootedTerminalReceiptKernel"
                    ]
                SourceGuard.countHaskellIdentifier "data" receiptSource @?= 0
                SourceGuard.countHaskellIdentifier "newtype" receiptSource @?= 0
                assertFragmentsInOrder
                    "the close request is admitted against the session before the report is published"
                    [ "case admit verbName path token ordinal predecessor of"
                    , "Left failure -> pure (Left failure)"
                    , "Right report -> do"
                    , "published <- publish report"
                    , "Right () -> use report (childConfigDigest signedComplete)"
                    ]
                    report
                assertFragmentsInOrder
                    "the close echoes this session's predecessor, and the report names this session's verb"
                    [ "echoed <- terminalRequest True request"
                    , "require \"the close request echoes another predecessor\" (namedPredecessor echoed == predecessor)"
                    , "nonce <- echoedRequest \"close\" path token ordinal echoed"
                    , "answer <- terminalResponse True \"FrameComplete\" signedComplete"
                    , "report <- echoedResponse \"FrameComplete\" path token ordinal nonce answer"
                    , "eliminateLifecycleReport"
                    , "require \"the terminal report names another verb\" (reportVerb == verbName)"
                    ]
                    report
                assertFragmentsInOrder
                    "a receipt names the exact completion digest before the durable advance runs"
                    [ "echoed <- terminalRequest False request"
                    , "require \"the receipt confirmation names another terminal report\" (namedPredecessor echoed == Just completion)"
                    , "answer <- terminalResponse False \"ReceiptRecorded\" signedReceipt"
                    , "recorded <- echoedResponse \"ReceiptRecorded\" path token ordinal nonce answer"
                    , "require \"the recorded receipt repeats another terminal report\" (recorded == TextEncoding.encodeUtf8 completion)"
                    ]
                    confirm
                assertFragmentsInOrder
                    "the confirmation admits, then advances, then derives its own digest"
                    [ "case admit path token ordinal of"
                    , "Left failure -> pure (Left failure)"
                    , "received <- receive"
                    , "Right () -> use (childConfigDigest signedReceipt)"
                    ]
                    confirm
                assertContains
                    "only a CloseFrame or ReceiptConfirm request reaches a terminal transition"
                    "\"only a \" <> (if close then \"CloseFrame\" else \"ReceiptConfirm\") <> \" request reaches this rooted terminal transition\""
                    (normalizeWhitespace receiptSource)
                assertContains
                    "each answer stays inside its own closed paired family"
                    "\"only a paired \" <> family <> \" or Refused response answers this rooted terminal request\""
                    (normalizeWhitespace receiptSource)
                assertContains
                    "a signed Refused is read as an outcome rather than minted"
                    "Left (receiptFailure (\"the rooted terminal request was refused: \" <> detail))"
                    (normalizeWhitespace receiptSource)
                mapM_
                    (\identifier -> SourceGuard.countHaskellIdentifier identifier receiptSource @?= 0)
                    [ "ProtectedStore"
                    , "ProtectedSession"
                    , "RecordKey"
                    , "withProtectedEntry"
                    , "compareAndSwapProtectedRecord"
                    , "publishLifecycleReportKernel"
                    , "receiveLifecycleAcknowledgementKernel"
                    , "renderLifecycleAcknowledgement"
                    , "recoverySigningKernel"
                    , "signRootedLifecycleResponseKernel"
                    , "rootedFrameCompleteResponseUnsignedKernel"
                    , "rootedReceiptRecordedResponseUnsignedKernel"
                    , "rootedRefusedResponseUnsignedKernel"
                    , "ProjectSigningKey"
                    , "RootBroker"
                    , "OpenedRootedFrameSession"
                    , "AttachedRootedFrameSession"
                    , "rootedFrameSessionKeyKernel"
                    , "unsafeCoerce"
                    ]
                mapM_
                    ( \moduleName ->
                        assertBool
                            ("the terminal receipt owner imports no store or transport owner " <> moduleName)
                            (not (SourceGuard.importsModule moduleName receiptSource))
                    )
                    [ "HostBootstrap.Chain"
                    , "HostBootstrap.Command"
                    , "HostBootstrap.Handoff.Protocol"
                    , "HostBootstrap.Handoff.Receiver"
                    , "HostBootstrap.Handoff.Relay"
                    , "HostBootstrap.Lifecycle.Session"
                    , "HostBootstrap.Protected"
                    , "System.Process"
                    ]
                assertBool
                    "neither neighbour names the terminal exchange it split out"
                    ( SourceGuard.countHaskellIdentifier "withRootedTerminalReportKernel" sessionOwnerSource == 0
                        && SourceGuard.countHaskellIdentifier "withRootedReceiptConfirmationKernel" sessionOwnerSource == 0
                        && SourceGuard.countHaskellIdentifier "withRootedTerminalReportKernel" nodeOwnerSource == 0
                        && SourceGuard.countHaskellIdentifier "withRootedReceiptConfirmationKernel" nodeOwnerSource == 0
                    )
                assertFragmentsInOrder
                    "the sole call site supplies publication first and the Published-to-Received advance second"
                    [ "withRootedTerminalReportKernel runtime session close signedComplete publish"
                    , "withRootedReceiptConfirmationKernel runtime session confirm completion signedReceipt (advance report) use"
                    , "published <- publishLifecycleReportKernel recoverySigningKernel store report"
                    , "advance report = case renderLifecycleAcknowledgement report of"
                    , "receiveLifecycleAcknowledgementKernel recoverySigningKernel store report acknowledgement"
                    ]
                    callSite
                sites "withRootedTerminalReportKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 3)
                        , ("HostBootstrap.Handoff.Relay", 2)
                        , ("HostBootstrap.Lifecycle.Rooted.Receipt", 4)
                        ]
                sites "withRootedReceiptConfirmationKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 3)
                        , ("HostBootstrap.Handoff.Relay", 2)
                        , ("HostBootstrap.Lifecycle.Rooted.Receipt", 4)
                        ]
                sites "withRootedTerminalReceiptKernel"
                    @?= [("HostBootstrap.Handoff.Relay", 3)]
                importers "HostBootstrap.Lifecycle.Rooted.Receipt"
                    @?= ["HostBootstrap.Command.LifecycleEntry", "HostBootstrap.Handoff.Relay"]
                importers "HostBootstrap.Lifecycle.Rooted"
                    @?= [ "HostBootstrap.Authority.FailedUp.Internal"
                        , "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.Handoff.Relay"
                        , "HostBootstrap.Handoff.TerminalReport"
                        , "HostBootstrap.Lifecycle.Rooted.Node"
                        , "HostBootstrap.Lifecycle.Rooted.Receipt"
                        ]
                assertBool
                    "the receipt and node split owners stay inside the 400-line boundary"
                    ( significantHaskellLineCount receiptSource < 400
                        && significantHaskellLineCount nodeOwnerSource < 400
                    )
        , testCase "the pure facade exposes only the abstract stable snapshot view" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                facadeSource <- readFile (sourceRoot </> "HostBootstrap" </> "ProjectPlan.hs")
                exportTokens <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan"
                        facadeSource
                assertBool
                    "StablePlanSnapshot is absent from the ProjectPlan export list"
                    ("StablePlanSnapshot" `elem` exportTokens)
                assertBool
                    "StablePlanSnapshot constructors are public"
                    (not (containsTokenSequence ["StablePlanSnapshot", "("] exportTokens))
                assertBool
                    "CanonicalPlanSnapshot is public through the pure facade"
                    ("CanonicalPlanSnapshot" `notElem` exportTokens)
                assertBool
                    "IndexedPlanSnapshot is public through the pure facade"
                    ("IndexedPlanSnapshot" `notElem` exportTokens)
                assertBool
                    "canonicalPlanSnapshot is public through the pure facade"
                    ("canonicalPlanSnapshot" `notElem` exportTokens)

                publicExports <- readPublicModuleExports packageRoot sourceRoot
                modulesExporting "IndexedPlanSnapshot" publicExports @?= []
                modulesExporting "canonicalPlanSnapshot" publicExports @?= []
                let planKernelReexports =
                        sort
                            [ moduleName
                            | (moduleName, exports) <- publicExports
                            , containsTokenSequence
                                [ "module"
                                , "HostBootstrap"
                                , "."
                                , "Lifecycle"
                                , "."
                                , "Plan"
                                ]
                                exports
                            ]
                planKernelReexports @?= []
                let exposedKernelImporters =
                        [ "HostBootstrap.ProjectPlan"
                        , "HostBootstrap.ProjectPlan.Construct"
                        , "HostBootstrap.ProjectPlan.Frame"
                        , "HostBootstrap.ProjectPlan.Snapshot"
                        , "HostBootstrap.Authority.ProjectPlan"
                        , "HostBootstrap.Lifecycle.Mode"
                        , "HostBootstrap.Lifecycle.Session"
                        , "HostBootstrap.Reconcile"
                        ]
                    moduleReexportingKernelImporters =
                        sort
                            [ moduleName
                            | (moduleName, exports) <- publicExports
                            , moduleName `elem` exposedKernelImporters
                            , "module" `elem` exports
                            ]
                moduleReexportingKernelImporters @?= []

                sources <- readProductionSources sourceRoot
                let canonicalSignatureSites =
                        [ (moduleName, count)
                        | (moduleName, _path, source) <- sources
                        , let count =
                                SourceGuard.countHaskellTokenSequence
                                    ["canonicalPlanSnapshot", "::"]
                                    source
                        , count > 0
                        ]
                canonicalSignatureSites
                    @?= [("HostBootstrap.Lifecycle.Plan", 1)]
        , testCase "reverse-root substrate is nominal, canonical, Down/Destroy-only, and sealed" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                modeSource <- readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Mode.hs")
                sessionSource <- readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Session.hs")
                snapshotSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Snapshot.hs")
                schema <-
                    requiredSourceSection
                        "private reverse-root schema"
                        "data ReverseRootIntent projectId sourceBrokerGeneration verb where"
                        "reverseRootIntentMagic ::"
                        modeSource
                codec <-
                    requiredSourceSection
                        "private reverse-root codec"
                        "reverseRootIntentMagic ::"
                        "{- | The Open branch:"
                        modeSource
                sourceEliminator <-
                    requiredSourceSection
                        "strict reverse-root source-record eliminator"
                        "withReverseRootSourceRecordsKernel ::"
                        "{- | Open or exactly resume one frame-local cursor."
                        sessionSource
                let sealedSchema = normalizeWhitespace schema
                    canonicalCodec = normalizeWhitespace codec
                    eliminator = normalizeWhitespace sourceEliminator
                mapM_
                    (\(label, fragment, source) -> assertContains label fragment source)
                    [
                        ( "the reverse-root intent's three nominal indices"
                        , "type role ReverseRootIntent nominal nominal nominal"
                        , sealedSchema
                        )
                    ,
                        ( "the Down Pending constructor"
                        , "ReverseRootDownPending ::"
                        , sealedSchema
                        )
                    ,
                        ( "the Destroy Pending constructor"
                        , "ReverseRootDestroyPending ::"
                        , sealedSchema
                        )
                    ,
                        ( "the Down Committed constructor"
                        , "ReverseRootDownCommitted ::"
                        , sealedSchema
                        )
                    ,
                        ( "the Destroy Committed constructor"
                        , "ReverseRootDestroyCommitted ::"
                        , sealedSchema
                        )
                    ,
                        ( "the Down Terminal constructor"
                        , "ReverseRootDownTerminal ::"
                        , sealedSchema
                        )
                    ,
                        ( "the Destroy Terminal constructor"
                        , "ReverseRootDestroyTerminal ::"
                        , sealedSchema
                        )
                    ,
                        ( "the committed redo suffix"
                        , "-> Word64 -> Word64 -> ByteString -> Word64 -> ByteString -> ReverseRootIntent"
                        , sealedSchema
                        )
                    ,
                        ( "the wire magic"
                        , "reverseRootIntentMagic = \"HOSTBOOTSTRAP-REVERSE-ROOT\""
                        , canonicalCodec
                        )
                    ,
                        ( "the wire version"
                        , "reverseRootIntentVersion = 1"
                        , canonicalCodec
                        )
                    ,
                        ( "the canonical field framing"
                        , "Builder.word64BE (fromIntegral (length fields)) <> foldMap encodeSnapshotBytes fields"
                        , canonicalCodec
                        )
                    ,
                        ( "the complete source and redo field order"
                        , "common state verb ( project , store , run , revision , spec , config , plan , canonical , source , acquisitionKey , acquisitionVersion , acquisitionBytes , cursorKey , cursorVersion , cursorBytes , rootFrame , sessions , modeVersion , modeBytes , leaseVersion , leaseBytes )"
                        , canonicalCodec
                        )
                    ,
                        ( "the explicit Up decoder refusal"
                        , "case expected of ProjectUp -> Nothing ProjectDown -> pure () ProjectDestroy -> pure ()"
                        , canonicalCodec
                        )
                    ,
                        ( "the exact canonical readback check"
                        , "encodeReverseRootIntent intent == raw = Just intent"
                        , canonicalCodec
                        )
                    ,
                        ( "the canonical-plan field bound"
                        , "ByteString.null canonical || ByteString.length canonical > maxCanonicalPlanBytes"
                        , canonicalCodec
                        )
                    ,
                        ( "the whole-row wire bound"
                        , "ByteString.length raw > maxSnapshotRecordBytes = Nothing"
                        , canonicalCodec
                        )
                    ,
                        ( "the field-count wire bound"
                        , "if count > 32 then Nothing else collect count payload []"
                        , canonicalCodec
                        )
                    ,
                        ( "the exact trailing-byte refusal"
                        , "collect 0 trailing fields | ByteString.null trailing = Just (reverse fields) | otherwise = Nothing"
                        , canonicalCodec
                        )
                    ,
                        ( "the exact committed 21-plus-5 shape"
                        , "case splitAt 21 commonValues of (base, [targetRaw, nextModeVersionRaw, nextModeBytes, nextLeaseVersionRaw, nextLeaseBytes])"
                        , canonicalCodec
                        )
                    ,
                        ( "the text field bound"
                        , "ByteString.length bytes > maxSnapshotTextBytes = Nothing"
                        , canonicalCodec
                        )
                    ,
                        ( "the nonempty acquisition source bytes"
                        , "if ByteString.null acquisitionBytes then Nothing else pure ()"
                        , canonicalCodec
                        )
                    ,
                        ( "the nonempty cursor source bytes"
                        , "if ByteString.null cursorBytes then Nothing else pure ()"
                        , canonicalCodec
                        )
                    ,
                        ( "positive source and record versions"
                        , "source <- positive sourceRaw acquisitionKey <- asText acquisitionKeyRaw >>= either (const Nothing) Just . mkRecordKey acquisitionVersion <- positive acquisitionVersionRaw"
                        , canonicalCodec
                        )
                    ,
                        ( "the hidden token's partial-application strictness"
                        , "withReverseRootSourceRecordsKernel admission = admission `seq` consumeReverseRootSourceAdmission admission eliminate"
                        , eliminator
                        )
                    ,
                        ( "the opaque strict source admission consumer"
                        , "{-# OPAQUE consumeReverseRootSourceAdmission #-} consumeReverseRootSourceAdmission admission result = case consumeAcquisitionJournalAdmissionKernel admission of () -> result"
                        , eliminator
                        )
                    ,
                        ( "the exact source verb and phase check"
                        , "projectVerbName verb == projectVerbName ProjectUp , lifecyclePhaseName phase == lifecyclePhaseName Teardown"
                        , eliminator
                        )
                    ]
                assertAbsent "an Up reverse-root constructor" "ReverseRootUp" sealedSchema
                assertAbsent "an Up phantom in the reverse-root schema" "VerbUp" sealedSchema
                SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" codec @?= 0
                SourceGuard.countHaskellIdentifier "compareAndDeleteProtectedRecord" codec @?= 0
                SourceGuard.countHaskellIdentifier "withReverseRootSourceRecordsKernel" modeSource @?= 2
                mapM_
                    (\(name, count) -> SourceGuard.countHaskellIdentifier name modeSource @?= count)
                    [ ("ReverseRootDownPending", 7)
                    , ("ReverseRootDestroyPending", 7)
                    , ("ReverseRootDownCommitted", 7)
                    , ("ReverseRootDestroyCommitted", 7)
                    , ("ReverseRootDownTerminal", 10)
                    , ("ReverseRootDestroyTerminal", 10)
                    , ("encodeReverseRootIntent", 9)
                    , ("decodeReverseRootIntent", 15)
                    , ("reverseRootIntentKey", 6)
                    , ("reverseRootIntentKeyForName", 5)
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name modeSource @?= 0)
                    [ "withReauthorizedBoundPlanSnapshotKernel"
                    , "advanceReverseRootIntent"
                    ]
                mapM_
                    (\source -> SourceGuard.countHaskellIdentifier "unsafeCoerce" source @?= 0)
                    [modeSource, sessionSource, snapshotSource]
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                modulesExporting "ReverseRootIntent" publicExports @?= []
                modulesExporting "AcquisitionJournalAdmission" publicExports @?= []
                sources <- readProductionSources sourceRoot
                let intentOwners =
                        [ moduleName
                        | (moduleName, _path, source) <- sources
                        , SourceGuard.countHaskellTokenSequence
                            ["data", "ReverseRootIntent", "projectId", "sourceBrokerGeneration", "verb", "where"]
                            source
                            == 1
                        ]
                    admissionOwners =
                        [ moduleName
                        | (moduleName, _path, source) <- sources
                        , SourceGuard.countHaskellTokenSequence
                            ["data", "AcquisitionJournalAdmission"]
                            source
                            == 1
                        ]
                    eliminatorSites =
                        [ moduleName
                        | (moduleName, _path, source) <- sources
                        , SourceGuard.countHaskellIdentifier
                            "withReverseRootSourceRecordsKernel"
                            source
                            > 0
                        ]
                    freshBrokerSites =
                        [ moduleName
                        | (moduleName, _path, source) <- sources
                        , SourceGuard.countHaskellIdentifier "withFreshBrokerEpochKernel" source > 0
                        ]
                    reverseKeyLiteralSites =
                        [ moduleName
                        | (moduleName, _path, source) <- sources
                        , "reverse-root." `Text.isInfixOf` Text.pack source
                        ]
                intentOwners @?= ["HostBootstrap.Lifecycle.Mode"]
                admissionOwners @?= ["HostBootstrap.Lifecycle.Plan"]
                eliminatorSites
                    @?= [ "HostBootstrap.Lifecycle.Mode"
                        , "HostBootstrap.Lifecycle.Session"
                        ]
                freshBrokerSites
                    @?= [ "HostBootstrap.Authority.Kernel"
                        , "HostBootstrap.Lifecycle.Mode"
                        ]
                reverseKeyLiteralSites @?= ["HostBootstrap.Lifecycle.Mode"]
                Text.count "reverse-root." (Text.pack modeSource) @?= 1
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                assertAbsent
                    "a Mode.Testing private-intent seam"
                    "HostBootstrap.Lifecycle.Mode.Testing"
                    cabalSource
                assertAbsent
                    "a Mode.Internal private-intent seam"
                    "HostBootstrap.Lifecycle.Mode.Internal"
                    cabalSource
        , testCase "reverse-root resume/redo is strict, exact, one-sided, and Snapshot-only" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                modeSource <- readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Mode.hs")
                transitionSource <-
                    requiredSourceSection
                        "reverse-root resume/redo transition"
                        "{- | Resume only the exact same-verb"
                        "-- End reverse-root transition kernels"
                        modeSource
                wrapperSource <-
                    requiredSourceSection
                        "strict reverse-root resume wrapper"
                        "withResumedExistingBoundReverseRootKernel ::"
                        "withExistingBoundReverseRootTransition ::"
                        transitionSource
                engineSource <-
                    requiredSourceSection
                        "private reverse-root transition engine"
                        "withExistingBoundReverseRootTransition ::"
                        "-- End reverse-root transition kernels"
                        modeSource
                pendingSource <-
                    requiredSourceSection
                        "reverse-root Pending transition"
                        "commitPending common encodeCommitted"
                        "finishCommitted"
                        engineSource
                committedSource <-
                    requiredSourceSection
                        "reverse-root Committed convergence"
                        "        finishCommitted common target"
                        "    validateCommon ::"
                        engineSource
                commonSource <-
                    requiredSourceSection
                        "reverse-root common delivery validation"
                        "    validateCommon ::"
                        "    readSuffix ::"
                        engineSource
                suffixSource <-
                    requiredSourceSection
                        "reverse-root suffix classification and readback"
                        "    readSuffix ::"
                        "    requireText subject expected observed"
                        engineSource
                existingRootSource <-
                    requiredSourceSection
                        "existing root binding verifier"
                        "withExistingVerifiedRoot ::"
                        "traverseEither ::"
                        modeSource
                let wrapper = normalizeWhitespace wrapperSource
                    engine = normalizeWhitespace engineSource
                    pending = normalizeWhitespace pendingSource
                    committed = normalizeWhitespace committedSource
                    common = normalizeWhitespace commonSource
                    suffix = normalizeWhitespace suffixSource
                    existingRoot = normalizeWhitespace existingRootSource
                mapM_
                    (\(label, fragment, source) -> assertContains label fragment source)
                    [
                        ( "the hidden token is the first resume argument"
                        , "ExistingBoundSnapshotAdmission -> ProtectedStore -> InstalledProjectIdentity projectId -> ProjectVerb verb ->"
                        , wrapper
                        )
                    ,
                        ( "the resume partial-application boundary is opaque"
                        , "{-# OPAQUE withResumedExistingBoundReverseRootKernel #-}"
                        , wrapper
                        )
                    ,
                        ( "the hidden token is forced before the remaining lambda"
                        , "withResumedExistingBoundReverseRootKernel admission = case consumeExistingBoundSnapshotAdmissionKernel admission of () -> \\store project verb use ->"
                        , wrapper
                        )
                    ,
                        ( "absence has one fixed generic refusal"
                        , "withExistingBoundReverseRootTransition store project verb (\\_ _ _ -> pure (Left ModeReverseRootInProgress)) use"
                        , wrapper
                        )
                    ,
                        ( "only Down and Destroy enter the shared transition"
                        , "ProjectUp -> pure (Left (ModeWrongRecoveryScope \"reverse root\" \"up\")) ProjectDown -> transition ProjectDestroy -> transition"
                        , engine
                        )
                    ,
                        ( "the requested verb drives exact canonical intent decoding"
                        , "decodeReverseRootIntent verb (protectedRecordBytes retained)"
                        , engine
                        )
                    ,
                        ( "Down recognizes only Destroy as the opposite intent"
                        , "ProjectDown -> maybe False (const True) (decodeReverseRootIntent ProjectDestroy bytes)"
                        , engine
                        )
                    ,
                        ( "Destroy recognizes only Down as the opposite intent"
                        , "ProjectDestroy -> maybe False (const True) (decodeReverseRootIntent ProjectDown bytes)"
                        , engine
                        )
                    ,
                        ( "an opposite intent is refused as in progress"
                        , "True -> pure (Left ModeReverseRootInProgress) False -> pure (Left (ModeMalformedRecord (recordKeyText intentKey)))"
                        , engine
                        )
                    ,
                        ( "the Pending intent has its exact initial durable version"
                        , "recordVersionWord (protectedRecordVersion intentRecord) /= 1"
                        , pending
                        )
                    ,
                        ( "the mode predecessor refuses version exhaustion"
                        , "oldModeVersion == maxBound"
                        , pending
                        )
                    ,
                        ( "the lease predecessor refuses version exhaustion"
                        , "oldLeaseVersion == maxBound"
                        , pending
                        )
                    ,
                        ( "the broker allocator is the direct protected kernel"
                        , "withFreshBrokerEpochKernel session project"
                        , pending
                        )
                    ,
                        ( "Pending publishes Committed only from its retained version"
                        , "compareAndSwapProtectedRecord session intentKey (ExpectVersion (protectedRecordVersion intentRecord)) bytes"
                        , pending
                        )
                    ,
                        ( "the committed descriptor is strictly read back"
                        , "readback <- exactWordRecord session intentKey 2 bytes"
                        , pending
                        )
                    ,
                        ( "Committed refuses a non-successor target before reification"
                        , "target <= source = mismatchIO \"committed broker generation\" \"greater than source\" (showWord target)"
                        , committed
                        )
                    ,
                        ( "only the committed target enters direct reification"
                        , "withReifiedAllocatedBrokerEpochKernel session project target"
                        , committed
                        )
                    ,
                        ( "old mode and old lease write mode first"
                        , "Right (False, False, modeRecord, leaseRecord) -> do modeWritten <- writeSuffix session (modeKey project) modeRecord nextModeVersion nextModeBytes"
                        , committed
                        )
                    ,
                        ( "new mode and old lease write only the lease"
                        , "Right (True, False, _, leaseRecord) -> do leaseWritten <- writeSuffix session"
                        , committed
                        )
                    ,
                        ( "new mode and new lease verify without a suffix write"
                        , "Right (True, True, _, _) -> deliver verified canonical epoch"
                        , committed
                        )
                    ,
                        ( "old mode and new lease are impossible"
                        , "Right (False, True, _, _) -> mismatchIO \"reverse-root suffix\" \"mode before lease\" \"old mode/new lease\""
                        , committed
                        )
                    ,
                        ( "suffix classification accepts only exact old bytes"
                        , "version == oldVersion && bytes == oldBytes = Right False"
                        , suffix
                        )
                    ,
                        ( "suffix classification accepts only exact new bytes"
                        , "version == newVersion && bytes == newBytes = Right True"
                        , suffix
                        )
                    ,
                        ( "every other suffix row conflicts"
                        , "otherwise = mismatch (\"reverse-root \" <> subject) \"exact old or new row\" \"different\""
                        , suffix
                        )
                    ,
                        ( "exact durable readback compares version and bytes"
                        , "recordVersionWord (protectedRecordVersion record) == expectedVersion , protectedRecordBytes record == expectedBytes"
                        , suffix
                        )
                    ,
                        ( "the target root uses the existing binding verifier"
                        , "withExistingVerifiedRootInvocationKernel scope session project operator epoch verb"
                        , existingRoot
                        )
                    ,
                        ( "the target callback gets one locally bound snapshot identity"
                        , "withPersistedBoundPlanSnapshotKernel canonical $ \\bound binding -> use verb root"
                        , committed
                        )
                    ,
                        ( "the target callback receives a recovered Production profile"
                        , "RecoveredProductionLifecycleProfile (ProductionRunIdentity productionRunKey) projectName storeIdentity revision spec plan config canonicalBytes epoch NormalRevision"
                        , committed
                        )
                    ]
                assertAbsent "the fixed absence refusal projects no raw key" "recordKeyText" wrapper
                assertFragmentsInOrder
                    "Pending validates exact source and predecessors before allocation and commit"
                    [ "validateCommon session location common"
                    , "exactWordRecord session key oldModeVersion oldModeBytes"
                    , "exactWordRecord session (leaseLocationLeaseKey location) oldLeaseVersion oldLeaseBytes"
                    , "withFreshBrokerEpochKernel session project"
                    , "target <= source"
                    , "compareAndSwapProtectedRecord session intentKey"
                    ]
                    pending
                assertFragmentsInOrder
                    "Committed validates before target reification, suffix convergence, and delivery"
                    [ "target <= source"
                    , "validateCommon session location common"
                    , "withReifiedAllocatedBrokerEpochKernel session project target"
                    , "suffix <- readSuffix"
                    , "case suffix of"
                    ]
                    committed
                assertFragmentsInOrder
                    "old/old convergence writes mode before lease and delivery"
                    [ "Right (False, False, modeRecord, leaseRecord)"
                    , "modeWritten <- writeSuffix"
                    , "leaseWritten <- writeSuffix"
                    , "Right () -> deliver verified canonical epoch"
                    ]
                    committed
                assertFragmentsInOrder
                    "every delivery uses fresh exact source and snapshot evidence"
                    [ "readInvocationDispositionAt session"
                    , "readOpenRevisionKindForKey session"
                    , "exactWordRecord session acquisitionKey acquisitionVersion acquisitionBytes"
                    , "exactWordRecord session cursorKey cursorVersion cursorBytes"
                    , "verifyAllSessionsClosed session plan"
                    , "readVerifiedPlanSnapshotAt session"
                    , "Right InvocationOpen"
                    , "Right NormalRevision"
                    , "requireText \"closed-session plan\" plan"
                    , "requireWord \"closed-session count\" sessions"
                    , "admitPersistedCanonicalPlanSnapshotKernel"
                    ]
                    common
                assertFragmentsInOrder
                    "intent, mode, and lease readback precede the target closure"
                    [ "intentRead <- exactWordRecord session intentKey 2"
                    , "modeRead <- withRecordKey"
                    , "leaseRead <- exactWordRecord"
                    , "case (intentRead, modeRead, leaseRead) of"
                    , "verifyOsPrincipal session"
                    , "withExistingVerifiedRoot ProductionRootScope"
                    , "withPersistedBoundPlanSnapshotKernel canonical"
                    , "use verb root"
                    ]
                    committed
                assertFragmentsInOrder
                    "the protected entry returns the callback before it is run"
                    [ "prepared <- runProtected store"
                    , "Right deliver -> Right <$> deliver"
                    ]
                    engine
                SourceGuard.countHaskellIdentifier "validateCommon" engineSource @?= 4
                SourceGuard.countHaskellIdentifier "withFreshBrokerEpochKernel" engineSource @?= 1
                SourceGuard.countHaskellIdentifier "withReifiedAllocatedBrokerEpochKernel" engineSource @?= 1
                SourceGuard.countHaskellIdentifier "withExistingVerifiedRoot" engineSource @?= 1
                SourceGuard.countHaskellIdentifier "withExistingBoundReverseRootTransition" modeSource @?= 4
                SourceGuard.countHaskellIdentifier "resumeExistingBoundReverseRootKernel" modeSource @?= 0
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name transitionSource @?= 0)
                    [ "ExpectAbsent"
                    , "withFreshEpoch"
                    , "withRecordedEpoch"
                    , "withReifiedRunId"
                    , "withVerifiedRoot"
                    , "withReverseRootSourceRecordsKernel"
                    , "withRunLiveness"
                    , "ProjectPlan"
                    , "AcquisitionJournal"
                    , "LifecycleCursor"
                    , "InvocationReservation"
                    , "LifecycleEntry"
                    , "unsafeCoerce"
                    , "normalize"
                    , "error"
                    , "undefined"
                    , "fromJust"
                    , "head"
                    , "tail"
                    , "init"
                    , "last"
                    , "data"
                    , "newtype"
                    , "type"
                    ]
                SourceGuard.countHaskellTokenSequence ["!!"] transitionSource @?= 0
                sources <- readProductionSources sourceRoot
                let resumeKernelSites =
                        [ (moduleName, count)
                        | (moduleName, _path, source) <- sources
                        , let count =
                                SourceGuard.countHaskellIdentifier
                                    "withResumedExistingBoundReverseRootKernel"
                                    source
                        , count > 0
                        ]
                resumeKernelSites
                    @?= [ ("HostBootstrap.Lifecycle.Mode", 4)
                        , ("HostBootstrap.ProjectPlan.Snapshot", 2)
                        ]
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                modulesExporting "withResumedExistingBoundReverseRootKernel" publicExports
                    @?= ["HostBootstrap.Lifecycle.Mode"]
                modulesExporting "resumeExistingBoundReverseRootKernel" publicExports @?= []
                modulesExporting "withExistingBoundReverseRootTransition" publicExports @?= []
        , testCase "reverse-root fresh admission is strict, exact, sole, and Snapshot-only" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                modeSource <- readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Mode.hs")
                freshSignatureSource <-
                    requiredSourceSection
                        "fresh reverse-root joint signature"
                        "withFreshExistingBoundReverseRootKernel ::"
                        "{-# OPAQUE withFreshExistingBoundReverseRootKernel #-}"
                        modeSource
                freshSource <-
                    requiredSourceSection
                        "fresh reverse-root admission"
                        "withFreshExistingBoundReverseRootKernel ::"
                        "{- | Resume only the exact same-verb"
                        modeSource
                engineSource <-
                    requiredSourceSection
                        "shared reverse-root transition engine"
                        "withExistingBoundReverseRootTransition ::"
                        "-- End reverse-root transition kernels"
                        modeSource
                liveSourceSection <-
                    requiredSourceSection
                        "fresh reverse-root live source validation"
                        "validateLiveSource profile rootFrameName sourceRecords = do"
                        "                            validateLiveRows\n                                acquisitionCurrent"
                        freshSource
                liveRowsSection <-
                    requiredSourceSection
                        "fresh reverse-root durable row validation"
                        "                            validateLiveRows\n                                acquisitionCurrent"
                        "publishPending profile"
                        freshSource
                pendingSection <-
                    requiredSourceSection
                        "fresh reverse-root Pending publication"
                        "publishPending profile rootFrameName sourceRecords proof modeRecord leaseRecord = do"
                        "exactSourceRecord key version bytes = do"
                        freshSource
                let signature = normalizeWhitespace freshSignatureSource
                    fresh = normalizeWhitespace freshSource
                    engine = normalizeWhitespace engineSource
                    liveSource = normalizeWhitespace liveSourceSection
                    liveRows = normalizeWhitespace liveRowsSection
                    pending = normalizeWhitespace pendingSection
                assertFragmentsInOrder
                    "the fresh wrapper jointly retains the exact source package"
                    [ "ExistingBoundSnapshotAdmission ->"
                    , "ProtectedStore ->"
                    , "InstalledProjectIdentity projectId ->"
                    , "ProjectVerb verb ->"
                    , "RootInvocationAuthority (Production projectId) sourceBrokerGeneration VerbUp ->"
                    , "ProjectModeLease projectId ProductionMode sourceBrokerGeneration ->"
                    , "BoundRunLease (Production projectId) sourceSpecDigest sourcePlanDigest sourceBrokerGeneration ->"
                    , "VerifiedPlanSnapshot (Production projectId) sourceSpecDigest sourcePlanDigest ->"
                    , "BoundPlanSnapshot (Production projectId) sourceSpecDigest sourcePlanDigest sourcePlanId ->"
                    , "PlanDigestBinding (Production projectId) sourceSpecDigest sourcePlanDigest sourcePlanId ->"
                    , "BoundInvocationRecovery (Production projectId) sourceSpecDigest sourcePlanDigest sourcePlanId sourceBrokerGeneration ->"
                    , "ProjectPlan (Production projectId) sourceSpecDigest sourcePlanId configId cfg ->"
                    , "ValidatedLifecycleContext (Production projectId) sourceSpecDigest sourcePlanId configId frame ->"
                    , "AcquisitionJournal (Production projectId) sourcePlanId sourceBrokerGeneration ->"
                    , "LifecycleCursor (Production projectId) sourcePlanId frame sourceBrokerGeneration VerbUp TeardownPhase ->"
                    ]
                    signature
                assertFragmentsInOrder
                    "the fresh wrapper preserves one jointly indexed target callback"
                    [ "LifecycleCursor (Production projectId) sourcePlanId frame sourceBrokerGeneration VerbUp TeardownPhase ->"
                    , "ProjectVerb verb ->"
                    , "RootInvocationAuthority (Production projectId) targetBrokerGeneration verb ->"
                    , "ProjectModeLease projectId ProductionMode targetBrokerGeneration ->"
                    , "BoundRunLease (Production projectId) targetSpecDigest targetPlanDigest targetBrokerGeneration ->"
                    , "VerifiedPlanSnapshot (Production projectId) targetSpecDigest targetPlanDigest ->"
                    , "BoundPlanSnapshot (Production projectId) targetSpecDigest targetPlanDigest targetPlanId ->"
                    , "PlanDigestBinding (Production projectId) targetSpecDigest targetPlanDigest targetPlanId ->"
                    , "RecoveredProductionLifecycleProfile projectId targetSpecDigest targetPlanDigest targetPlanId targetBrokerGeneration ->"
                    , "IO result ) -> IO (Either ModeError result)"
                    ]
                    signature
                mapM_
                    (\(label, fragment, source) -> assertContains label fragment source)
                    [
                        ( "the fresh partial-application boundary is opaque"
                        , "{-# OPAQUE withFreshExistingBoundReverseRootKernel #-}"
                        , fresh
                        )
                    ,
                        ( "the hidden token is forced before the remaining lambda"
                        , "withFreshExistingBoundReverseRootKernel admission = case consumeExistingBoundSnapshotAdmissionKernel admission of () -> \\store project verb sourceRoot sourceMode sourceBound sourceVerified sourceBoundSnapshot sourceBinding sourceRecovery sourcePlan lifecycleContext sourceJournal sourceCursor use ->"
                        , fresh
                        )
                    ,
                        ( "the fresh wrapper supplies the private absent hook"
                        , "withExistingBoundReverseRootTransition store project verb ( \\session location intentKey -> admitFresh session location intentKey encodePending ) use"
                        , fresh
                        )
                    ,
                        ( "the complete seven-value source is validated together"
                        , "validateRecoveredProductionLifecycleProfile sourceRoot sourceMode sourceBound sourceVerified sourceBoundSnapshot sourceBinding sourceRecovery"
                        , fresh
                        )
                    ,
                        ( "only a Normal source revision continues"
                        , "recoveredProductionProfileRevisionKind profile of NormalRevision -> admitRootContext profile"
                        , fresh
                        )
                    ,
                        ( "the supplied lifecycle context is root-refined"
                        , "withValidatedRootLifecycleContext lifecycleContext"
                        , fresh
                        )
                    ,
                        ( "the root frame is taken from the refined context"
                        , "projectFrameId rootFrame"
                        , fresh
                        )
                    ,
                        ( "the refined root frame equals the source cursor frame"
                        , "requireText \"context frame\" rootFrameName (lifecycleCursorFrame sourceCursor)"
                        , fresh
                        )
                    ,
                        ( "the reconstructed plan retains the exact profile epoch"
                        , "requireWord \"plan broker generation\" (brokerEpochWord sourceEpoch) (projectPlanProfileEpochKernel sourcePlan)"
                        , fresh
                        )
                    ,
                        ( "the reconstructed plan retains the exact canonical bytes"
                        , "requireBytes \"plan canonical bytes\" canonicalBytes (canonicalPlanSnapshotBytes planCanonical)"
                        , fresh
                        )
                    ,
                        ( "the bound lease is joined to the supplied journal"
                        , "validateBoundRunLeaseAcquisitionJournal sourceBound sourceJournal"
                        , fresh
                        )
                    ,
                        ( "the Session eliminator supplies only exact source coordinates"
                        , "withReverseRootSourceRecordsKernel acquisitionJournalAdmissionKernel sourceJournal sourceCursor (,,,,,)"
                        , fresh
                        )
                    ,
                        ( "the current cursor is revalidated in the protected entry"
                        , "validateCurrentLifecycleCursor session sourceCursor"
                        , liveSource
                        )
                    ,
                        ( "the exact acquisition record is raw-compared"
                        , "acquisitionCurrent <- exactSourceRecord acquisitionKey acquisitionVersion acquisitionBytes"
                        , liveSource
                        )
                    ,
                        ( "the exact cursor record is raw-compared"
                        , "cursorCurrentRecord <- exactSourceRecord cursorKey cursorVersion cursorBytes"
                        , liveSource
                        )
                    ,
                        ( "the source mode is read in the same entry"
                        , "modeCurrent <- requiredRecord (modeKey project)"
                        , liveSource
                        )
                    ,
                        ( "the source lease is read in the same entry"
                        , "leaseCurrent <- requiredRecord (Right (leaseLocationLeaseKey location))"
                        , liveSource
                        )
                    ,
                        ( "the source snapshot is reread in the same entry"
                        , "snapshotCurrent <- readVerifiedPlanSnapshotAt session"
                        , liveSource
                        )
                    ,
                        ( "the source invocation disposition is reread"
                        , "dispositionCurrent <- readInvocationDispositionAt session"
                        , liveSource
                        )
                    ,
                        ( "the source revision kind is reread"
                        , "revisionCurrent <- readOpenRevisionKindForKey session project productionRunKey"
                        , liveSource
                        )
                    ,
                        ( "the mode predecessor must have a successor version"
                        , "requireBelowMax \"mode record version\" (recordVersionWord (protectedRecordVersion modeRecord))"
                        , liveRows
                        )
                    ,
                        ( "the lease predecessor must have a successor version"
                        , "requireBelowMax \"lease record version\" (recordVersionWord (protectedRecordVersion leaseRecord))"
                        , liveRows
                        )
                    ,
                        ( "only an Open invocation is admitted"
                        , "Right InvocationOpen -> Right ()"
                        , liveRows
                        )
                    ,
                        ( "only a Normal durable revision is admitted"
                        , "Right NormalRevision -> Right ()"
                        , liveRows
                        )
                    ,
                        ( "Pending records the exact closed-session count"
                        , "fromIntegral (allSessionsClosedCount proof)"
                        , pending
                        )
                    ,
                        ( "Pending is the sole absent compare-and-swap"
                        , "compareAndSwapProtectedRecord session intentKey ExpectAbsent pendingBytes"
                        , pending
                        )
                    ,
                        ( "Pending requires its canonical initial version"
                        , "recordVersionWord version /= 1"
                        , pending
                        )
                    ,
                        ( "Pending is strictly read back at version one"
                        , "recordVersionWord (protectedRecordVersion record) == 1 , protectedRecordBytes record == pendingBytes"
                        , pending
                        )
                    ,
                        ( "the shared engine calls the absent hook under its protected entry"
                        , "prepared <- runProtected store $ \\session -> do"
                        , engine
                        )
                    ,
                        ( "only observed absence invokes the supplied hook"
                        , "record <- maybe (admit session location intentKey) (pure . Right) current"
                        , engine
                        )
                    ]
                assertFragmentsInOrder
                    "fresh durable rows are classified before root reauthorization and Pending"
                    [ "acquisitionCurrent <- exactSourceRecord"
                    , "cursorCurrentRecord <- exactSourceRecord"
                    , "modeCurrent <- requiredRecord"
                    , "leaseCurrent <- requiredRecord"
                    , "snapshotCurrent <- readVerifiedPlanSnapshotAt"
                    , "dispositionCurrent <- readInvocationDispositionAt"
                    , "revisionCurrent <- readOpenRevisionKindForKey"
                    , "case validateLiveRows"
                    , "Right (modeRecord, leaseRecord) -> do"
                    , "operator <- verifyOsPrincipal session"
                    , "withExistingVerifiedRoot ProductionRootScope"
                    , "(projectModeLeaseEpoch sourceMode) ProjectUp"
                    , "recovered <- recoverAbandonedSessions session"
                    , "closed <- case recovered of"
                    , "verifyAllSessionsClosed session"
                    , "publishPending profile rootFrameName sourceRecords proof modeRecord leaseRecord"
                    ]
                    liveSource
                assertFragmentsInOrder
                    "Pending is encoded, published, version-checked, and read back before handoff"
                    [ "pendingBytes = encodePending common"
                    , "compareAndSwapProtectedRecord session intentKey ExpectAbsent pendingBytes"
                    , "recordVersionWord version /= 1"
                    , "observed <- readProtectedRecord session intentKey"
                    , "recordVersionWord (protectedRecordVersion record) == 1"
                    , "protectedRecordBytes record == pendingBytes"
                    ]
                    pending
                SourceGuard.countHaskellIdentifier
                    "validateRecoveredProductionLifecycleProfile"
                    freshSource
                    @?= 1
                SourceGuard.countHaskellIdentifier "withExistingBoundReverseRootTransition" freshSource
                    @?= 1
                SourceGuard.countHaskellIdentifier "withExistingBoundReverseRootTransition" modeSource
                    @?= 4
                SourceGuard.countHaskellIdentifier "ExpectAbsent" freshSource @?= 1
                SourceGuard.countHaskellIdentifier "ExpectVersion" freshSource @?= 2
                SourceGuard.countHaskellIdentifier "compareAndDeleteProtectedRecord" freshSource @?= 1
                SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" freshSource @?= 2
                SourceGuard.countHaskellIdentifier "requireBelowMax" freshSource @?= 3
                SourceGuard.countHaskellIdentifier "maxBound" freshSource @?= 1
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name freshSource @?= 0)
                    [ "withFreshBrokerEpochKernel"
                    , "withFreshEpoch"
                    , "withRecordedEpoch"
                    , "withReifiedAllocatedBrokerEpochKernel"
                    , "withReifiedBrokerEpochKernel"
                    , "withVerifiedRoot"
                    , "withRunLiveness"
                    , "InvocationReservation"
                    , "LifecycleEntry"
                    , "unsafeCoerce"
                    , "normalize"
                    , "error"
                    , "undefined"
                    , "fromJust"
                    , "head"
                    , "tail"
                    , "init"
                    , "last"
                    , "data"
                    , "newtype"
                    , "type"
                    ]
                SourceGuard.countHaskellTokenSequence ["!!"] freshSource @?= 0
                sources <- readProductionSources sourceRoot
                let freshKernelSites =
                        [ (moduleName, count)
                        | (moduleName, _path, source) <- sources
                        , let count =
                                SourceGuard.countHaskellIdentifier
                                    "withFreshExistingBoundReverseRootKernel"
                                    source
                        , count > 0
                        ]
                freshKernelSites
                    @?= [ ("HostBootstrap.Lifecycle.Mode", 4)
                        , ("HostBootstrap.ProjectPlan.Snapshot", 2)
                        ]
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                modulesExporting "withFreshExistingBoundReverseRootKernel" publicExports
                    @?= ["HostBootstrap.Lifecycle.Mode"]
        , testCase "reverse-root Snapshot selection is strict, liveness-scoped, and caller-sealed" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                snapshotSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Snapshot.hs")
                facadeSource <-
                    case dropThrough
                        "{- | Reauthorize one existing-bound Production root"
                        snapshotSource of
                        Nothing ->
                            assertFailure "the reverse-root Snapshot facade section is absent"
                                >> pure ""
                        Just section -> pure section
                resumeBranch <-
                    requiredSourceSection
                        "reverse-root Snapshot resume branch"
                        "Left ModeReverseRootInProgress -> do"
                        "Left failure ->"
                        facadeSource
                targetSignature <-
                    requiredSourceSection
                        "reverse-root Snapshot target callback"
                        "( forall targetBrokerGeneration targetSpecDigest targetPlanDigest targetPlanId."
                        "IO (Either SnapshotError result)"
                        facadeSource
                let facade = normalizeWhitespace facadeSource
                mapM_
                    (\(label, fragment, source) -> assertContains label fragment source)
                    [
                        ( "the hidden token is the first facade argument"
                        , "withReauthorizedBoundPlanSnapshotKernel :: ExistingBoundSnapshotAdmission -> ProtectedStore -> InstalledProjectIdentity projectId -> ProjectVerb verb ->"
                        , facade
                        )
                    ,
                        ( "the operational partial-application boundary is opaque"
                        , "{-# OPAQUE withReauthorizedBoundPlanSnapshotKernel #-}"
                        , facade
                        )
                    ,
                        ( "the hidden token is forced before the remaining lambda"
                        , "withReauthorizedBoundPlanSnapshotKernel admission = case consumeExistingBoundSnapshotAdmissionKernel admission of () -> \\store project verb initialSource use ->"
                        , facade
                        )
                    ,
                        ( "the selector relays the same hidden admission"
                        , "withBoundPlanSnapshotKernel admission store project"
                        , facade
                        )
                    ,
                        ( "the terminal selector discards its close key"
                        , "(\\_closeKey -> pure (Left SnapshotReverseRootTerminal))"
                        , facade
                        )
                    ,
                        ( "only the Open callback invokes source reconstruction"
                        , "( \\root modeLease boundLease verified boundSnapshot binding recovery -> initialSource root modeLease boundLease verified boundSnapshot binding recovery"
                        , facade
                        )
                    ,
                        ( "fresh admission receives only the reconstructed source continuation"
                        , "( \\plan lifecycleContext journal cursor -> do transitioned <- withFreshExistingBoundReverseRootKernel admission store project verb root modeLease boundLease verified boundSnapshot binding recovery plan lifecycleContext journal cursor use pure (fromMode transitioned) )"
                        , facade
                        )
                    ,
                        ( "only the selector's outer InProgress failure resumes"
                        , "case selected of Left ModeReverseRootInProgress -> do resumed <- withResumedExistingBoundReverseRootKernel admission store project verb use pure (fromMode resumed) Left failure -> pure (Left (SnapshotVerificationError failure)) Right outcome -> pure outcome"
                        , facade
                        )
                    ,
                        ( "the sole liveness extent contains the complete selector"
                        , "held <- withRunLiveness store (installedProjectName project) select"
                        , facade
                        )
                    ,
                        ( "liveness acquisition failure is classified truthfully"
                        , "Left failure -> Left (SnapshotLivenessFailure failure)"
                        , facade
                        )
                    ,
                        ( "live-peer contention is classified truthfully"
                        , "Right Nothing -> Left SnapshotLivenessContended"
                        , facade
                        )
                    ,
                        ( "the callback result is returned before liveness releases"
                        , "Right (Just outcome) -> outcome"
                        , facade
                        )
                    ,
                        ( "Up is refused without selecting the liveness action"
                        , "in case verb of ProjectUp -> pure ( Left ( SnapshotVerificationError (ModeWrongRecoveryScope \"reverse root\" \"up\") ) ) ProjectDown -> underLiveness ProjectDestroy -> underLiveness"
                        , facade
                        )
                    ]
                assertFragmentsInOrder
                    "fresh and resumed target callbacks remain inside the one liveness body"
                    [ "select = do"
                    , "withBoundPlanSnapshotKernel"
                    , "initialSource"
                    , "withFreshExistingBoundReverseRootKernel"
                    , "case selected of"
                    , "Left ModeReverseRootInProgress"
                    , "withResumedExistingBoundReverseRootKernel"
                    , "underLiveness = do"
                    , "withRunLiveness store (installedProjectName project) select"
                    , "in case verb of"
                    ]
                    facade
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name facadeSource @?= 1)
                    [ "consumeExistingBoundSnapshotAdmissionKernel"
                    , "withBoundPlanSnapshotKernel"
                    , "withFreshExistingBoundReverseRootKernel"
                    , "withResumedExistingBoundReverseRootKernel"
                    , "withRunLiveness"
                    , "ModeReverseRootInProgress"
                    ]
                SourceGuard.countHaskellIdentifier "initialSource" facadeSource @?= 2
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name resumeBranch @?= 0)
                    [ "initialSource"
                    , "root"
                    , "modeLease"
                    , "boundLease"
                    , "verified"
                    , "boundSnapshot"
                    , "binding"
                    , "recovery"
                    , "plan"
                    , "lifecycleContext"
                    , "journal"
                    , "cursor"
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name targetSignature @?= 0)
                    [ "ProjectPlan"
                    , "ValidatedLifecycleContext"
                    , "AcquisitionJournal"
                    , "LifecycleCursor"
                    , "InvocationReservation"
                    , "LifecycleEntry"
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name facadeSource @?= 0)
                    [ "existingBoundSnapshotAdmissionKernel"
                    , "InvocationCloseKey"
                    , "invocationCloseKeyText"
                    , "recordKeyText"
                    , "runProtected"
                    , "withProtectedEntry"
                    , "readProtectedRecord"
                    , "decodeReverseRootIntent"
                    , "withFreshEpoch"
                    , "withRecordedEpoch"
                    , "compareAndSwapProtectedRecord"
                    , "compareAndDeleteProtectedRecord"
                    , "InvocationReservation"
                    , "LifecycleEntry"
                    , "unsafeCoerce"
                    , "error"
                    , "undefined"
                    , "data"
                    , "newtype"
                    , "type"
                    ]
                SourceGuard.countHaskellTokenSequence ["!!"] facadeSource @?= 0
                sources <- readProductionSources sourceRoot
                let wrapperSites name =
                        [ (moduleName, count)
                        | (moduleName, _path, source) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name source
                        , count > 0
                        ]
                wrapperSites "withFreshExistingBoundReverseRootKernel"
                    @?= [ ("HostBootstrap.Lifecycle.Mode", 4)
                        , ("HostBootstrap.ProjectPlan.Snapshot", 2)
                        ]
                wrapperSites "withResumedExistingBoundReverseRootKernel"
                    @?= [ ("HostBootstrap.Lifecycle.Mode", 4)
                        , ("HostBootstrap.ProjectPlan.Snapshot", 2)
                        ]
                wrapperSites "withReauthorizedBoundPlanSnapshotKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 2)
                        , ("HostBootstrap.ProjectPlan.Snapshot", 4)
                        ]
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                modulesExporting "withReauthorizedBoundPlanSnapshotKernel" publicExports
                    @?= ["HostBootstrap.ProjectPlan.Snapshot"]
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                assertAbsent
                    "a Snapshot.Testing reverse-root seam"
                    "HostBootstrap.ProjectPlan.Snapshot.Testing"
                    cabalSource
                assertAbsent
                    "a Snapshot.Internal reverse-root seam"
                    "HostBootstrap.ProjectPlan.Snapshot.Internal"
                    cabalSource
        , testCase "reverse-root entry sealing is hidden, target-derived, and phase-ordered" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                entrySource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Command" </> "LifecycleEntry.hs")
                sessionSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Session.hs")
                modeSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Mode.hs")
                constructSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Construct.hs")
                reverseEntry <-
                    requiredSourceSection
                        "reverse-root lifecycle-entry producer"
                        "withRootProjectReverseLifecycleEntry ::"
                        "{- | Admit exactly one authenticated child Up/Execute entry."
                        entrySource
                sourceCallback <-
                    requiredSourceSection
                        "reverse-root source callback"
                        "( \\sourceRoot sourceMode sourceLease sourceVerified sourceBound sourceBinding"
                        "( \\targetVerb targetRoot targetMode targetLease targetVerified targetBound"
                        reverseEntry
                targetCallback <-
                    requiredSourceSection
                        "reverse-root target callback"
                        "( \\targetVerb targetRoot targetMode targetLease targetVerified targetBound"
                        "pure $ case admitted of"
                        reverseEntry
                sealerSection <-
                    requiredSourceSection
                        "reverse-root catalog sealer"
                        "sealReverseRootEntry ::"
                        "{- | Prepare a descent only from a sealed root Down or Destroy entry."
                        reverseEntry
                targetCursorKernel <-
                    requiredSourceSection
                        "reverse-root target cursor kernel"
                        "withReverseRootTargetLifecycleCursorKernel ::"
                        "{- | Open or exactly resume one frame-local cursor."
                        sessionSource
                acquisitionGate <-
                    requiredSourceSection
                        "generic acquisition journal gate"
                        "withAcquisitionJournal ::"
                        "{- | Sealed config-origin child recovery."
                        modeSource
                recoveredPlanGate <-
                    requiredSourceSection
                        "fixed-identity recovered Production plan gate"
                        "withRecoveredProductionProjectPlan ::"
                        "requireText :: Text -> Text -> Text -> Either PlanError ()"
                        constructSource
                constructorSection <-
                    requiredSourceSection
                        "closed lifecycle-entry constructors"
                        "data LifecycleEntry scope planId frame brokerGeneration verb where"
                        "type role LifecycleEntry nominal nominal nominal nominal nominal"
                        entrySource
                let entry = normalizeWhitespace reverseEntry
                    source = normalizeWhitespace sourceCallback
                    target = normalizeWhitespace targetCallback
                    sealer = normalizeWhitespace sealerSection
                    cursor = normalizeWhitespace targetCursorKernel
                    acquisition = normalizeWhitespace acquisitionGate
                    recovered = normalizeWhitespace recoveredPlanGate
                    constructors = normalizeWhitespace constructorSection
                mapM_
                    (\(label, fragment, body) -> assertContains label fragment body)
                    [
                        ( "the hidden producer owns the Snapshot admission token"
                        , "withReauthorizedBoundPlanSnapshotKernel existingBoundSnapshotAdmissionKernel store project verb"
                        , entry
                        )
                    ,
                        ( "the producer callback retains only fresh target indices"
                        , "( forall targetBroker targetPlanId targetFrame. LifecycleEntry (Production projectId) targetPlanId targetFrame targetBroker verb -> ( SubtreeSettled (Production projectId) targetPlanId targetFrame verb -> IO (Either String ()) ) -> IO (Either String ()) )"
                        , entry
                        )
                    ,
                        ( "the source callback reconstructs the exact Up lineage and bridges a retained failed Execute"
                        , "withAcquisitionJournalPhase journal $ \\seedPhase -> case seedPhase of Prepare -> do current <- withCurrentLifecycleCursor journal frame ProjectUp ( \\phase cursor -> case phase of Prepare -> sourcePhaseFailure \"prepare\" Execute -> do transitioned <- withTeardownLifecycleCursor cursor (continue sourcePlan lifecycleContext journal) pure (either sourceSessionFailure id transitioned) Teardown -> continue sourcePlan lifecycleContext journal cursor"
                        , source
                        )
                    ,
                        ( "the absent-only source refuses a mutated Execute seed"
                        , "Execute -> sourceSeedFailure \"execute\""
                        , source
                        )
                    ,
                        ( "the absent-only source refuses a mutated Teardown seed"
                        , "Teardown -> sourceSeedFailure \"teardown\""
                        , source
                        )
                    ,
                        ( "source seed refusal maps through the Snapshot error channel"
                        , "sourceSeedFailure = pure . sourceMismatch \"reverse-root source acquisition seed\" \"prepare\""
                        , entry
                        )
                    ,
                        ( "the target callback rebuilds from its recovered profile"
                        , "withRecoveredProductionProjectPlan targetProfile root targetVerified targetBound targetBinding targetConfig targetDrafts"
                        , target
                        )
                    ,
                        ( "the rebuilt target plan is checked at the callback epoch"
                        , "if projectPlanProfileEpochKernel targetPlan /= targetEpoch then pure (Left \"lifecycle entry: target plan broker epoch differs\")"
                        , target
                        )
                    ,
                        ( "the target journal is derived from the same target package"
                        , "withAcquisitionJournal targetRoot targetLease targetBound targetBinding targetPlan"
                        , target
                        )
                    ,
                        ( "the target cursor consumes the one hidden journal admission"
                        , "withReverseRootTargetLifecycleCursorKernel acquisitionJournalAdmissionKernel journal frame targetVerb"
                        , target
                        )
                    ,
                        ( "authorization consumes the callback-derived Teardown cursor"
                        , "ProjectAuthority.authorizeRootProject targetRoot targetVerb targetVerified targetBound targetBinding targetLease targetPlan journal teardownCursor lifecycleContext"
                        , target
                        )
                    ,
                        ( "the reverse target delegates sealing to the one catalog-admitting sealer"
                        , "Right authority -> sealReverseRootEntry targetSpec targetVerb targetRoot targetPlan targetCurrent lifecycleContext journal teardownCursor authority reauthorize ( \\entry -> use entry"
                        , target
                        )
                    ,
                        ( "Down seals only the Down constructor before callback delivery"
                        , "ProjectDown -> withReverseRootCatalog finalized root plan current lifecycleContext $ \\catalog -> use ( RootDownLifecycleEntry root verb plan lifecycleContext journal cursor authority reauthorize catalog )"
                        , sealer
                        )
                    ,
                        ( "Destroy seals only the Destroy constructor before callback delivery"
                        , "ProjectDestroy -> withReverseRootCatalog finalized root plan current lifecycleContext $ \\catalog -> use ( RootDestroyLifecycleEntry root verb plan lifecycleContext journal cursor authority reauthorize catalog )"
                        , sealer
                        )
                    ,
                        ( "the target cursor admission is token-first and opaque"
                        , "{-# OPAQUE withReverseRootTargetLifecycleCursorKernel #-} withReverseRootTargetLifecycleCursorKernel admission = case consumeAcquisitionJournalAdmissionKernel admission of () -> \\journal@(AcquisitionJournal store validateLive _ sourceVersion _ seedPhase) frame verb use ->"
                        , cursor
                        )
                    ,
                        ( "Up is a total target refusal"
                        , "ProjectUp -> pure (Left (SessionCursorVerbMismatch \"down or destroy\" \"up\"))"
                        , cursor
                        )
                    ,
                        ( "the immutable target acquisition seed must remain Prepare"
                        , "let advance = case seedPhase of Prepare | recordVersionWord sourceVersion == 1 -> case validateLifecycleCursorRequest journal frame verb of"
                        , cursor
                        )
                    ,
                        ( "an Execute acquisition seed is refused"
                        , "Execute -> refuseAcquisition \"seed phase\" \"prepare\" \"execute\""
                        , cursor
                        )
                    ,
                        ( "a Teardown acquisition seed is refused"
                        , "Teardown -> refuseAcquisition \"seed phase\" \"prepare\" \"teardown\""
                        , cursor
                        )
                    ,
                        ( "seed refusal maps to the exact lifecycle error"
                        , "refuseAcquisition field expected observed = pure (Left (SessionAcquisitionBindingMismatch field expected observed))"
                        , cursor
                        )
                    ,
                        ( "retained liveness is revalidated before the current cursor"
                        , "inLifecycleCursorEntry store $ \\session -> do live <- validateLive session case live of Left failure -> pure (Left failure) Right () -> do current <- openCurrentLifecycleCursorInEntry session Nothing journal frame verb"
                        , cursor
                        )
                    ,
                        ( "Prepare version one advances through Execute two before Teardown three"
                        , "Prepare -> case checkedVersion 1 cursor of Left failure -> pure (Left failure) Right prepareCursor -> do executed <- advanceLifecycleCursorInEntry session prepareCursor Execute case executed >>= checkedVersion 2 of Left failure -> pure (Left failure) Right executeCursor -> do teardown <- advanceLifecycleCursorInEntry session executeCursor Teardown pure (teardown >>= checkedVersion 3)"
                        , cursor
                        )
                    ,
                        ( "Execute version two advances only to Teardown three"
                        , "Execute -> case checkedVersion 2 cursor of Left failure -> pure (Left failure) Right executeCursor -> do teardown <- advanceLifecycleCursorInEntry session executeCursor Teardown pure (teardown >>= checkedVersion 3)"
                        , cursor
                        )
                    ,
                        ( "Teardown version three redelivers without another transition"
                        , "Teardown -> pure (checkedVersion 3 cursor)"
                        , cursor
                        )
                    ,
                        ( "the target callback runs only after the protected entry returns"
                        , "either (pure . Left) (fmap Right . use) terminal"
                        , cursor
                        )
                    ,
                        ( "the generic journal keeps root epoch equality"
                        , "requireWord \"root broker epoch\" epochWord (brokerEpochWord (rootAuthorityEpoch root))"
                        , acquisition
                        )
                    ,
                        ( "the generic journal keeps plan epoch equality"
                        , "requireWord \"plan broker epoch\" epochWord (projectPlanProfileEpochKernel plan)"
                        , acquisition
                        )
                    ,
                        ( "the live lease keeps the same target epoch"
                        , "requireWord \"live lease broker epoch\" epochWord liveEpoch"
                        , acquisition
                        )
                    ,
                        ( "the recovered plan verifies bound canonical bytes"
                        , "requireBytes \"bound snapshot canonical bytes\" profileBytes (boundPlanSnapshotBytes bound)"
                        , recovered
                        )
                    ,
                        ( "the recovered plan verifies candidate canonical bytes"
                        , "requireBytes \"candidate canonical bytes\" profileBytes (stablePlanSnapshotBytes snapshot)"
                        , recovered
                        )
                    ,
                        ( "the recovered plan verifies the candidate digest"
                        , "requireText \"candidate plan digest\" profilePlan (stablePlanSnapshotDigest snapshot)"
                        , recovered
                        )
                    ,
                        ( "the Down entry has a Teardown cursor and authority"
                        , "RootDownLifecycleEntry :: RootInvocationAuthority scope brokerGeneration VerbDown -> ProjectVerb VerbDown -> ProjectPlan scope specDigest planId configId cfg -> ValidatedLifecycleContext scope specDigest planId configId frame -> AcquisitionJournal scope planId brokerGeneration -> LifecycleCursor scope planId frame brokerGeneration VerbDown TeardownPhase -> CommandAuthority scope planId frame brokerGeneration VerbDown TeardownPhase -> IO ( Either Authority.AuthorityError (CommandAuthority scope planId frame brokerGeneration VerbDown TeardownPhase) ) -> RootedPlanCatalog scope planId brokerGeneration catalogId -> LifecycleEntry scope planId frame brokerGeneration VerbDown"
                        , constructors
                        )
                    ,
                        ( "the Destroy entry has a Teardown cursor and authority"
                        , "RootDestroyLifecycleEntry :: RootInvocationAuthority scope brokerGeneration VerbDestroy -> ProjectVerb VerbDestroy -> ProjectPlan scope specDigest planId configId cfg -> ValidatedLifecycleContext scope specDigest planId configId frame -> AcquisitionJournal scope planId brokerGeneration -> LifecycleCursor scope planId frame brokerGeneration VerbDestroy TeardownPhase -> CommandAuthority scope planId frame brokerGeneration VerbDestroy TeardownPhase -> IO ( Either Authority.AuthorityError (CommandAuthority scope planId frame brokerGeneration VerbDestroy TeardownPhase) ) -> RootedPlanCatalog scope planId brokerGeneration catalogId -> LifecycleEntry scope planId frame brokerGeneration VerbDestroy"
                        , constructors
                        )
                    ]
                assertFragmentsInOrder
                    "source and target are sibling callbacks of the one Snapshot facade call"
                    [ "withReauthorizedBoundPlanSnapshotKernel"
                    , "( \\sourceRoot sourceMode sourceLease"
                    , "continue sourcePlan lifecycleContext journal cursor"
                    , "( \\targetVerb targetRoot targetMode targetLease"
                    , "withRecoveredProductionProjectPlan targetProfile"
                    , "withReverseRootTargetLifecycleCursorKernel"
                    , "ProjectAuthority.authorizeRootProject"
                    , "RootDownLifecycleEntry"
                    , "RootDestroyLifecycleEntry"
                    ]
                    entry
                assertFragmentsInOrder
                    "target cursor phases are exhaustive and monotone"
                    [ "case seedPhase of"
                    , "Prepare"
                    , "recordVersionWord sourceVersion == 1"
                    , "validateLifecycleCursorRequest journal frame verb"
                    , "inLifecycleCursorEntry store"
                    , "validateLive session"
                    , "openCurrentLifecycleCursorInEntry session Nothing journal frame verb"
                    , "case phase of"
                    , "Prepare -> case checkedVersion 1 cursor"
                    , "advanceLifecycleCursorInEntry session prepareCursor Execute"
                    , "checkedVersion 2"
                    , "advanceLifecycleCursorInEntry session executeCursor Teardown"
                    , "checkedVersion 3"
                    , "Execute -> case checkedVersion 2 cursor"
                    , "advanceLifecycleCursorInEntry session executeCursor Teardown"
                    , "checkedVersion 3"
                    , "Teardown -> pure (checkedVersion 3 cursor)"
                    , "either (pure . Left) (fmap Right . use) terminal"
                    , "Execute -> refuseAcquisition \"seed phase\" \"prepare\" \"execute\""
                    , "Teardown -> refuseAcquisition \"seed phase\" \"prepare\" \"teardown\""
                    ]
                    cursor
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name targetCallback @?= 0)
                    [ "sourceRoot"
                    , "sourceMode"
                    , "sourceLease"
                    , "sourceVerified"
                    , "sourceBound"
                    , "sourceBinding"
                    , "sourceRecovery"
                    , "sourceProfile"
                    , "sourceConfig"
                    , "sourceDrafts"
                    , "sourcePlan"
                    , "continue"
                    , "withCurrentLifecycleCursor"
                    , "withReverseRootSourceRecordsKernel"
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name reverseEntry @?= 0)
                    [ "withRunLiveness"
                    , "unsafeCoerce"
                    , "undefined"
                    , "error"
                    , "newtype"
                    , "data"
                    , "type"
                    , "RootReverseLifecycleEntry"
                    , "ReverseLifecycleEntry"
                    ]
                SourceGuard.countHaskellIdentifier "withLifecycleCursor" targetCursorKernel @?= 0
                SourceGuard.countHaskellIdentifier "withAcquisitionJournalPhase" targetCursorKernel @?= 0
                SourceGuard.countHaskellIdentifier "withCurrentLifecycleCursor" targetCursorKernel @?= 0
                SourceGuard.countHaskellIdentifier "withExecuteLifecycleCursor" targetCursorKernel @?= 0
                SourceGuard.countHaskellIdentifier "withTeardownLifecycleCursor" targetCursorKernel @?= 0
                SourceGuard.countHaskellIdentifier "inLifecycleCursorEntry" targetCursorKernel @?= 1
                SourceGuard.countHaskellIdentifier "openCurrentLifecycleCursorInEntry" targetCursorKernel @?= 1
                SourceGuard.countHaskellIdentifier "advanceLifecycleCursorInEntry" targetCursorKernel @?= 3
                SourceGuard.countHaskellIdentifier "withRunLiveness" targetCursorKernel @?= 0
                SourceGuard.countHaskellIdentifier "unsafeCoerce" targetCursorKernel @?= 0
                SourceGuard.countHaskellIdentifier "RootDownLifecycleEntry" targetCallback @?= 0
                SourceGuard.countHaskellIdentifier "RootDestroyLifecycleEntry" targetCallback @?= 0
                SourceGuard.countHaskellIdentifier "sealReverseRootEntry" targetCallback @?= 1
                SourceGuard.countHaskellIdentifier "RootDownLifecycleEntry" sealerSection @?= 1
                SourceGuard.countHaskellIdentifier "RootDestroyLifecycleEntry" sealerSection @?= 1
                SourceGuard.countHaskellIdentifier "withAcquisitionJournalPhase" sourceCallback @?= 1
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name entrySource @?= 10)
                    ["RootDownLifecycleEntry", "RootDestroyLifecycleEntry"]
                sources <- readProductionSources sourceRoot
                let sites name =
                        [ (moduleName, count)
                        | (moduleName, _path, sourceBody) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name sourceBody
                        , count > 0
                        ]
                sites "withReauthorizedBoundPlanSnapshotKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 2)
                        , ("HostBootstrap.ProjectPlan.Snapshot", 4)
                        ]
                sites "withRootProjectReverseLifecycleEntry"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 3)
                        , ("HostBootstrap.Command", 2)
                        ]
                sites "withReverseRootTargetLifecycleCursorKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 3)
                        , ("HostBootstrap.Lifecycle.Mode", 2)
                        , ("HostBootstrap.Lifecycle.Session", 4)
                        ]
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                modulesExporting "withRootProjectReverseLifecycleEntry" publicExports @?= []
                modulesExporting "withReverseRootTargetLifecycleCursorKernel" publicExports
                    @?= ["HostBootstrap.Lifecycle.Session"]
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                Text.count "HostBootstrap.Command.LifecycleEntry" (Text.pack cabalSource) @?= 1
                mapM_
                    (\name -> assertAbsent "a reverse-root runtime testing seam" name cabalSource)
                    [ "HostBootstrap.Command.LifecycleEntry.Testing"
                    , "HostBootstrap.Authority.Kernel.Testing"
                    ]
                sessionTesting <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Session" </> "Testing.hs")
                SourceGuard.countHaskellIdentifier
                    "withReverseRootTargetLifecycleCursorKernel"
                    sessionTesting
                    @?= 0
        , testCase "the reverse-descent substrate is hidden, nominal, and durably ordered" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                internalSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Teardown" </> "Internal.hs")
                teardownSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Teardown.hs")
                entrySource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Command" </> "LifecycleEntry.hs")
                familySource <-
                    requiredSourceSection
                        "the prepared reverse-descent family"
                        "{- | One parent-local reverse descent through its durable lifecycle states."
                        "-- | Derive the exact plan-owned launch context retained by one reverse edge."
                        internalSource
                signatureSource <-
                    requiredSourceSection
                        "the prepared reverse-descent kernel signature"
                        "{- | Prepare one exact root-entry descent, or return its unchanged work."
                        "withPreparedReverseDescentKernel admission ="
                        internalSource
                admissionSource <-
                    requiredSourceSection
                        "the prepared reverse-descent admission body"
                        "withPreparedReverseDescentKernel admission ="
                        "{- | Bind one prepared descent to the exact recoverably opened offer."
                        internalSource
                adapterVerifierSource <-
                    requiredSourceSection
                        "the canonical reverse-adapter verifier"
                        "{- | Verify one canonical reverse adapter against its exact local projection."
                        "renderReverseAdapter :: Text -> ProjectVerb verb -> Text -> Text -> [Text] -> ByteString"
                        internalSource
                internalExports <-
                    maybe
                        (assertFailure "HostBootstrap.Teardown.Internal has no explicit export list")
                        pure
                        ( SourceGuard.moduleExportTokens
                            "HostBootstrap.Teardown.Internal"
                            internalSource
                        )
                let internal = normalizeWhitespace internalSource
                    family = normalizeWhitespace familySource
                    signature = normalizeWhitespace signatureSource
                    admission = normalizeWhitespace admissionSource
                    adapterVerifier = normalizeWhitespace adapterVerifierSource
                    teardown = normalizeWhitespace teardownSource
                    exports = filter (/= ",") internalExports
                exports
                    @?= [ "ReverseDescent"
                        , "withReverseDescentLiftContextKernel"
                        , "withReverseDescentProcessInputsKernel"
                        , "withPreparedReverseForestKernel"
                        , "withPreparedReverseAdmissionsKernel"
                        , "renderPreparedReverseTerminalOriginKernel"
                        , "withPreparedReverseDescentKernel"
                        , "withBoundReverseDescentKernel"
                        , "withRehydratedBoundReverseDescentKernel"
                        , "withRehydratedAdoptedReverseDescentKernel"
                        , "withRehydratedSettledReverseDescentKernel"
                        , "withVerifiedBoundReverseDescentReportKernel"
                        , "withVerifiedBoundReverseDescentObservationsKernel"
                        , "withVerifiedReverseAdapterKernel"
                        ]
                mapM_
                    (\(label, fragment, body) -> assertContains label fragment body)
                    [
                        ( "the substrate has one eight-index state family"
                        , "data ReverseDescent state scope planId parentFrame childFrame brokerGeneration verb descentId where"
                        , family
                        )
                    ,
                        ( "Prepared is the unit-state constructor"
                        , "PreparedReverseDescent :: RootInvocationAuthority scope brokerGeneration verb"
                        , family
                        )
                    ,
                        ( "Prepared returns only the unit state"
                        , "ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId"
                        , family
                        )
                    ,
                        ( "Bound nests the exact Prepared identity without changing descent identity"
                        , "BoundReverseDescent :: ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId -> ByteString -> RecordVersion -> ByteString -> ReverseDescent (HandoffOffer scope brokerGeneration) scope planId parentFrame childFrame brokerGeneration verb descentId"
                        , family
                        )
                    ,
                        ( "all eight state-family roles are nominal"
                        , "type role ReverseDescent nominal nominal nominal nominal nominal nominal nominal nominal"
                        , family
                        )
                    ,
                        ( "the constructor retains the original descent work"
                        , "DescentWork scope planId parentFrame childFrame verb"
                        , family
                        )
                    ,
                        ( "the constructor retains the canonical binding input, adapter, and digest"
                        , "HandoffBindingInput -> ByteString -> Text -> [Text]"
                        , family
                        )
                    ,
                        ( "the constructor retains the private ordered completion verifier"
                        , "( [(Text, TeardownOutcome)] -> Either TeardownError (SubtreeSettled scope planId childFrame verb) )"
                        , family
                        )
                    ,
                        ( "the constructor retains the exact durable readback"
                        , "ProtectedStore -> RecordKey -> RecordVersion -> ByteString"
                        , family
                        )
                    ,
                        ( "the hidden token is the first kernel argument"
                        , "withPreparedReverseDescentKernel :: Plan.AcquisitionJournalAdmission -> RootInvocationAuthority"
                        , signature
                        )
                    ,
                        ( "the kernel receives only the typed descent package"
                        , "DescentWork scope planId parentFrame childFrame verb"
                        , signature
                        )
                    ,
                        ( "the result keeps a fresh unselectable descent identity"
                        , "forall descentId. ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId -> IO result"
                        , signature
                        )
                    ,
                        ( "every refusal returns the unchanged work"
                        , "IO (Either (TeardownError, DescentWork scope planId parentFrame childFrame verb) result)"
                        , signature
                        )
                    ,
                        ( "the kernel is opaque and token-first"
                        , "{-# OPAQUE withPreparedReverseDescentKernel #-} withPreparedReverseDescentKernel admission = case Plan.consumeAcquisitionJournalAdmissionKernel admission of () -> prepareEntry"
                        , internal
                        )
                    ,
                        ( "the exact child projection supplies canonical ordered operations"
                        , "withDescentWorkSubtree descent $ \\childProjection -> case openTeardownForest childProjection of Left failure -> pure (Left (failure, descent)) Right childForest -> let expected = teardownForestOutstanding childForest"
                        , admission
                        )
                    ,
                        ( "the adapter is derived internally and joined to the catalog child config"
                        , "case catalogPackage parent child expected of Left detail -> pure (Left (refusal detail, descent)) Right (childPlanDigest, adapter, childConfig, configDigest, package) ->"
                        , admission
                        )
                    ,
                        ( "the complete package comes only from the admitted edge and the frozen constructor"
                        , "catalogPackage parent child expected = do (childPlanDigest, childConfig, configDigest) <- withRootedPlanCatalogEdgeKernel catalog parent child selectChildConfig let adapter = renderReverseAdapter childPlanDigest verb parent child expected package <- recoveryChildPackageKernel childConfig adapter pure (childPlanDigest, adapter, childConfig, configDigest, renderRecoveryChildPackageKernel package)"
                        , admission
                        )
                    ,
                        ( "the catalog fold narrows to the canonical child config and its digest"
                        , "selectChildConfig _parentCurrent _plan binding _current _raw _route payload configDigest _payloadDigest _keys = (Plan.planDigestBindingDigestKernel binding, payload, configDigest)"
                        , admission
                        )
                    ,
                        ( "the binding input is derived from sealed terms"
                        , "input = HandoffBindingInput { requestedSpecDigest = specDigest , requestedPayloadKind = RecoveryAdapterWire , requestedPlanRevision = childPlanDigest , requestedParentFrame = parent , requestedChildFrame = child , requestedChildConfigDigest = packageDigest , requestedPhase = \"teardown\" }"
                        , admission
                        )
                    ,
                        ( "the prepared bytes are derived before validation and storage"
                        , "bytes = renderPrepared root journal cursor snapshot invocation input packageDigest configDigest package"
                        , admission
                        )
                    ,
                        ( "the retained command reservation is exactly replayed"
                        , "replayed <- reauthorize case replayed of Left _ -> refused descent \"the exact command reservation is stale\" Right authority | not (sameCommandAuthority store retained authority) -> refused descent \"the replayed command authority differs\""
                        , admission
                        )
                    ,
                        ( "the cursor is revalidated inside the protected entry"
                        , "admitted <- withProtectedEntry store $ \\session -> do currentCursor <- validateCurrentLifecycleCursor session cursor"
                        , admission
                        )
                    ,
                        ( "construction follows the protected-entry result"
                        , "case admitted of Left _ -> refused descent \"the prepared store entry failed\" Right (Left failure) -> pure (Left (failure, descent)) Right (Right version) -> Right <$> use ( PreparedReverseDescent"
                        , admission
                        )
                    ,
                        ( "the catalog child configuration, its digest, and the exact package are revalidated"
                        , "require \"the catalog child configuration is empty\" (not (ByteString.null childConfig)) require \"the catalog child configuration digest differs\" (configDigest == childConfigDigest childConfig) require \"the recovery package does not carry the exact catalog child configuration and adapter\" (package == renderedPackage) require \"the recovery package exceeds the handoff bound\" (fromIntegral (ByteString.length package) <= maxWireBytes) require \"the recovery package and child configuration digests are conflated\" (childConfigDigest package /= configDigest)"
                        , admission
                        )
                    ,
                        ( "the expected package is rerendered from the same two admitted fields"
                        , "renderedPackage = either (const ByteString.empty) renderRecoveryChildPackageKernel (recoveryChildPackageKernel childConfig adapter)"
                        , admission
                        )
                    ,
                        ( "the durable prepared record frames both digests and the complete package"
                        , "frameWire (renderHandoffBindingInput input) , framedText packageDigest , framedText configDigest , frameWire package"
                        , admission
                        )
                    ,
                        ( "the same parent and child frame is refused"
                        , "require \"the parent and child frames are equal\" (parent /= child)"
                        , admission
                        )
                    ,
                        ( "the child order is nonempty and duplicate-free"
                        , "require \"the child observation order is empty\" (not (null expected)) require \"the child observation order contains duplicates\" (length expected == length (nub expected))"
                        , admission
                        )
                    ,
                        ( "the recovery adapter is nonempty and bounded"
                        , "require \"the recovery adapter is empty\" (not (ByteString.null adapter)) require \"the recovery adapter exceeds the handoff bound\" (fromIntegral (ByteString.length adapter) <= maxWireBytes)"
                        , admission
                        )
                    ,
                        ( "the complete Prepared bytes are bounded before publication"
                        , "require \"the prepared record exceeds the handoff bound\" (fromIntegral (ByteString.length preparedBytes) <= maxWireBytes)"
                        , admission
                        )
                    ,
                        ( "the durable key binds invocation and adapter digests"
                        , "\"reverse-descent.\" <> recoveryWireDigest (TextEncoding.encodeUtf8 invocation) <> \".\" <> adapterDigest"
                        , admission
                        )
                    ,
                        ( "an existing durable row is admitted only through the exact state classifier"
                        , "Right (Just record) -> pure (classifyPrepared expected record)"
                        , admission
                        )
                    ,
                        ( "a stored collision refuses"
                        , "conflict = Left (refusal \"a conflicting prepared record exists\")"
                        , admission
                        )
                    ,
                        ( "absence alone enters the compare-and-swap"
                        , "Right Nothing -> do written <- compareAndSwapProtectedRecord session key ExpectAbsent expected"
                        , admission
                        )
                    ,
                        ( "fresh construction rereads and reclassifies the exact durable state"
                        , "readback <- readProtectedRecord session key pure $ case readback of Right (Just record) -> classifyPrepared expected record"
                        , admission
                        )
                    ,
                        ( "the adapter has one versioned length-framed vocabulary"
                        , "framedText \"hostbootstrap/reverse-descent-adapter\" , framedWord 1 , framedText planDigest , framedText parent , framedText child , framedText (projectVerbName closedVerb) , framedText \"teardown\" , framedWord (fromIntegral (length expected))"
                        , internal
                        )
                    ,
                        ( "the adapter fixes the three terminal outcomes"
                        , "framedWord 3 , framedText \"released\" , framedText \"foreign-retained\" , framedText \"refused\""
                        , internal
                        )
                    ,
                        ( "the prepared row binds durable root, journal, cursor, plan, adapter, and phase terms"
                        , "framedText \"hostbootstrap/reverse-descent\" , framedWord 1 , framedText \"prepared\" , framedText (acquisitionJournalStableScope journalEvidence) , framedText (rootAuthorityProjectName rootEvidence) , framedText (rootAuthorityStoreIdentity rootEvidence)"
                        , admission
                        )
                    ,
                        ( "the private verifier first compares the exact operation order"
                        , "map fst observations /= teardownForestOutstanding opened -> mismatch opened observations"
                        , internal
                        )
                    ,
                        ( "the private verifier rejects failed observations"
                        , "any failed observations -> Left (TeardownNonTerminalObservations observations)"
                        , internal
                        )
                    ,
                        ( "the private verifier replays nested rows through their exact child projection"
                        , "let childCount = length (teardownForestOutstanding childForest) (childRows, rest) = splitAt childCount remaining childSettled <- verifyChildObservations childProjection childRows successor <- settleDescentWork descent childSettled replay successor rest"
                        , internal
                        )
                    ,
                        ( "the public refusal remains structured"
                        , "TeardownReverseDescentRefused Text"
                        , teardown
                        )
                    ,
                        ( "the public refusal has an exact message mapping"
                        , "TeardownReverseDescentRefused detail -> \"teardown: reverse descent refused: \" <> Text.unpack detail"
                        , teardown
                        )
                    ,
                        ( "the hidden verifier consumes one exact local plan and matching current frame"
                        , "withVerifiedReverseAdapterKernel :: ProjectPlan scope specDigest planId configId cfg -> CurrentFrame scope planId localFrame -> ProjectVerb verb -> ByteString -> (TeardownPlan scope planId localFrame verb -> result) -> Either TeardownError result"
                        , adapterVerifier
                        )
                    ,
                        ( "the hidden verifier totally refuses Up and admits only Down or Destroy"
                        , "case verb of ProjectUp -> Left (refusal \"project up has no reverse adapter\") ProjectDown -> verify ProjectDestroy -> verify"
                        , adapterVerifier
                        )
                    ,
                        ( "the local frame must have exactly one plan-derived parent"
                        , "case parentFrames of [parent] ->"
                        , adapterVerifier
                        )
                    ,
                        ( "the local projection is derived only from the supplied plan, frame, and typed verb"
                        , "projection = teardownPlan plan current verb"
                        , adapterVerifier
                        )
                    ,
                        ( "the adapter plan digest is re-rendered from the exact local plan"
                        , "planDigest = stablePlanSnapshotDigest (renderSnapshot plan)"
                        , adapterVerifier
                        )
                    ,
                        ( "projection failure yields no plan"
                        , "case openTeardownForest projection of Left failure -> Left failure"
                        , adapterVerifier
                        )
                    ,
                        ( "the canonical adapter is re-rendered from exact local order"
                        , "expected = teardownForestOutstanding forest canonical = renderReverseAdapter planDigest verb parent child expected"
                        , adapterVerifier
                        )
                    ,
                        ( "byte drift refuses before the exact projection callback"
                        , "observed /= canonical -> Left (refusal \"the supplied reverse adapter is not canonical\") | otherwise -> Right (use projection)"
                        , adapterVerifier
                        )
                    ,
                        ( "non-unique or absent local ancestry yields no plan"
                        , "_ -> Left (refusal \"the current frame is not one exact topology child\")"
                        , adapterVerifier
                        )
                    ]
                assertFragmentsInOrder
                    "preparation derives, validates, reauthorizes, persists, rereads, unlocks, then calls back"
                    [ "withDescentWorkSubtree descent"
                    , "expected = teardownForestOutstanding childForest"
                    , "case catalogPackage parent child expected of"
                    , "let packageDigest = childConfigDigest package"
                    , "input = HandoffBindingInput"
                    , "bytes = renderPrepared"
                    , "withRootedPlanCatalogEdgeKernel catalog parent child selectChildConfig"
                    , "recoveryChildPackageKernel childConfig adapter"
                    , "validate store current frame"
                    , "keyFor invocation (recoveryWireDigest package)"
                    , "replayed <- reauthorize"
                    , "sameCommandAuthority store retained authority"
                    , "withProtectedEntry store"
                    , "validateCurrentLifecycleCursor session cursor"
                    , "admit session key bytes"
                    , "case admitted of"
                    , "Right (Right version)"
                    , "use"
                    , "PreparedReverseDescent"
                    ]
                    admission
                assertFragmentsInOrder
                    "the hidden verifier refuses drift before yielding its exact local projection"
                    [ "withVerifiedReverseAdapterKernel plan current verb observed use ="
                    , "case verb of"
                    , "ProjectUp -> Left"
                    , "ProjectDown -> verify"
                    , "ProjectDestroy -> verify"
                    , "case parentFrames of"
                    , "[parent]"
                    , "openTeardownForest projection"
                    , "observed /= canonical"
                    , "Left (refusal \"the supplied reverse adapter is not canonical\")"
                    , "otherwise -> Right (use projection)"
                    ]
                    adapterVerifier
                assertFragmentsInOrder
                    "the absent record path is CAS followed by strict state reclassification"
                    [ "observed <- readProtectedRecord session key"
                    , "Right Nothing"
                    , "compareAndSwapProtectedRecord session key ExpectAbsent expected"
                    , "Right version"
                    , "recordVersionWord version /= 1"
                    , "otherwise -> reread"
                    , "readback <- readProtectedRecord session key"
                    , "classifyPrepared expected record"
                    ]
                    admission
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name signatureSource @?= 0)
                    [ "Text"
                    , "ByteString"
                    , "HandoffBindingInput"
                    , "RecordKey"
                    , "RecordVersion"
                    , "TeardownOutcome"
                    , "HandoffChannel"
                    , "HandoffOffer"
                    , "HandoffToken"
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name admissionSource @?= 0)
                    [ "settleDescentWork"
                    , "failDescentWork"
                    , "attemptLocalWork"
                    , "attemptPreDescentStep"
                    , "verifySubtreeSettled"
                    , "openHandoffEdge"
                    , "registerHandoffEdge"
                    , "grantHandoff"
                    , "mkHandoffOffer"
                    , "HandoffOffer"
                    , "HandoffToken"
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name adapterVerifierSource @?= 0)
                    [ "Text"
                    , "TeardownOutcome"
                    , "DescentWork"
                    , "LifecycleCursor"
                    , "CommandAuthority"
                    , "HandoffBindingInput"
                    , "HandoffChannel"
                    , "RecordKey"
                    , "RecordVersion"
                    , "ProtectedStore"
                    ]
                SourceGuard.countHaskellIdentifier "failDescentWork" internalSource @?= 0
                SourceGuard.countHaskellIdentifier "settleDescentWork" internalSource @?= 1
                SourceGuard.countHaskellIdentifier "PreparedReverseDescent" familySource @?= 1
                SourceGuard.countHaskellIdentifier "PreparedReverseDescent" internalSource @?= 14
                SourceGuard.countHaskellTokenSequence ["data", "ReverseDescent"] internalSource @?= 1
                SourceGuard.countHaskellTokenSequence ["type", "ReverseDescent"] internalSource @?= 0
                SourceGuard.countHaskellIdentifier "BoundReverseDescent" internalSource @?= 10
                SourceGuard.countHaskellIdentifier "unsafeCoerce" internalSource @?= 0
                assertBool
                    "the hidden substrate imports only the lower Teardown boundary"
                    (SourceGuard.importsModule "HostBootstrap.Teardown" internalSource)
                mapM_
                    ( \moduleName ->
                        assertBool
                            ("the hidden substrate imports no upward module " <> moduleName)
                            (not (SourceGuard.importsModule moduleName internalSource))
                    )
                    [ "HostBootstrap.Command"
                    , "HostBootstrap.Command.LifecycleEntry"
                    , "HostBootstrap.Chain"
                    , "HostBootstrap.Handoff.Relay"
                    , "HostBootstrap.Handoff.Receiver"
                    ]
                assertBool
                    "the reverse lifecycle-entry producer adopts the prepared substrate"
                    (SourceGuard.importsModule "HostBootstrap.Teardown.Internal" entrySource)
                sources <- readProductionSources sourceRoot
                let sites name =
                        [ (moduleName, count)
                        | (moduleName, _path, sourceBody) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name sourceBody
                        , count > 0
                        ]
                    importers moduleName =
                        [ sourceModule
                        | (sourceModule, _path, sourceBody) <- sources
                        , SourceGuard.importsModule moduleName sourceBody
                        ]
                sites "withPreparedReverseDescentKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 3)
                        , ("HostBootstrap.Teardown.Internal", 4)
                        ]
                sites "PreparedReverseDescent"
                    @?= [("HostBootstrap.Teardown.Internal", 14)]
                sites "BoundReverseDescent"
                    @?= [("HostBootstrap.Teardown.Internal", 10)]
                sites "withBoundReverseDescentKernel"
                    @?= [ ("HostBootstrap.Handoff.Relay", 2)
                        , ("HostBootstrap.Teardown.Internal", 4)
                        ]
                sites "withRehydratedBoundReverseDescentKernel"
                    @?= [("HostBootstrap.Teardown.Internal", 6)]
                sites "withRehydratedAdoptedReverseDescentKernel"
                    @?= [ ("HostBootstrap.Handoff.Completion", 2)
                        , ("HostBootstrap.Teardown.Internal", 4)
                        ]
                sites "withRehydratedSettledReverseDescentKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 2)
                        , ("HostBootstrap.Teardown.Internal", 4)
                        ]
                sites "withVerifiedBoundReverseDescentObservationsKernel"
                    @?= [ ("HostBootstrap.Handoff.Completion", 2)
                        , ("HostBootstrap.Teardown.Internal", 4)
                        ]
                sites "withVerifiedReverseAdapterKernel"
                    @?= [ ("HostBootstrap.ProjectPlan.Child.Internal", 2)
                        , ("HostBootstrap.Teardown.Internal", 3)
                        ]
                importers "HostBootstrap.Teardown.Internal"
                    @?= [ "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.Handoff.Completion"
                        , "HostBootstrap.Handoff.Process"
                        , "HostBootstrap.Handoff.Relay"
                        , "HostBootstrap.ProjectPlan.Child.Internal"
                        ]
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                modulesExporting "ReverseDescent" publicExports @?= []
                modulesExporting "PreparedReverseDescent" publicExports @?= []
                modulesExporting "BoundReverseDescent" publicExports @?= []
                modulesExporting "withPreparedReverseDescentKernel" publicExports @?= []
                modulesExporting "withReverseDescentLiftContextKernel" publicExports @?= []
                modulesExporting "withBoundReverseDescentKernel" publicExports @?= []
                modulesExporting "withRehydratedBoundReverseDescentKernel" publicExports @?= []
                modulesExporting "withRehydratedSettledReverseDescentKernel" publicExports @?= []
                modulesExporting "withVerifiedBoundReverseDescentReportKernel" publicExports @?= []
                modulesExporting "withVerifiedBoundReverseDescentObservationsKernel" publicExports @?= []
                modulesExporting "withVerifiedReverseAdapterKernel" publicExports @?= []
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                librarySource <-
                    maybe
                        (assertFailure "the main library stanza is missing")
                        pure
                        (mainLibraryStanza cabalSource)
                let exposedModules = fieldModules "exposed-modules:" librarySource
                    otherModules = fieldModules "other-modules:" librarySource
                length (filter (== "HostBootstrap.Teardown.Internal") otherModules) @?= 1
                assertBool
                    "HostBootstrap.Teardown.Internal is not exposed"
                    ("HostBootstrap.Teardown.Internal" `notElem` exposedModules)
                Text.count "HostBootstrap.Teardown.Internal" (Text.pack cabalSource) @?= 1
                mapM_
                    (\name -> assertAbsent "a private preparation runtime seam" name cabalSource)
                    [ "HostBootstrap.Teardown.Testing"
                    , "HostBootstrap.Teardown.Internal.Testing"
                    , "HostBootstrap.Command.LifecycleEntry.Testing"
                    ]
        , testCase "root reverse-descent preparation is exact, sealed, and effect-free" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                entrySource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Command" </> "LifecycleEntry.hs")
                internalSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Teardown" </> "Internal.hs")
                commandSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Command.hs")
                constructorSection <-
                    requiredSourceSection
                        "closed lifecycle-entry constructors"
                        "data LifecycleEntry scope planId frame brokerGeneration verb where"
                        "type role LifecycleEntry nominal nominal nominal nominal nominal"
                        entrySource
                targetCallback <-
                    requiredSourceSection
                        "reverse-root target callback"
                        "( \\targetVerb targetRoot targetMode targetLease targetVerified targetBound"
                        "pure $ case admitted of"
                        entrySource
                sealerSection <-
                    requiredSourceSection
                        "reverse-root catalog sealer"
                        "sealReverseRootEntry ::"
                        "{- | Prepare a descent only from a sealed root Down or Destroy entry."
                        entrySource
                producerSignature <-
                    requiredSourceSection
                        "root prepared-descent producer signature"
                        "{- | Prepare a descent only from a sealed root Down or Destroy entry."
                        "withPreparedRootReverseDescentKernel entry descent use ="
                        entrySource
                producerBody <-
                    requiredSourceSection
                        "root prepared-descent producer body"
                        "withPreparedRootReverseDescentKernel entry descent use ="
                        "{- | Prepare one failed-Up cleanup descent without entering a reverse"
                        entrySource
                refusalSection <-
                    requiredSourceSection
                        "root prepared-descent refusal"
                        "    refused ="
                        "{- | Prepare one failed-Up cleanup descent without entering a reverse"
                        entrySource
                entryExports <-
                    maybe
                        (assertFailure "HostBootstrap.Command.LifecycleEntry has no explicit export list")
                        pure
                        ( SourceGuard.moduleExportTokens
                            "HostBootstrap.Command.LifecycleEntry"
                            entrySource
                        )
                let constructors = normalizeWhitespace constructorSection
                    target = normalizeWhitespace targetCallback
                    sealer = normalizeWhitespace sealerSection
                    signature = normalizeWhitespace producerSignature
                    producer = normalizeWhitespace producerBody
                    refusal = normalizeWhitespace refusalSection
                    internal = normalizeWhitespace internalSource
                    exports = filter (/= ",") entryExports
                mapM_
                    (\(label, fragment, body) -> assertContains label fragment body)
                    [
                        ( "the Down constructor privately retains its exact replay action"
                        , "CommandAuthority scope planId frame brokerGeneration VerbDown TeardownPhase -> IO ( Either Authority.AuthorityError (CommandAuthority scope planId frame brokerGeneration VerbDown TeardownPhase) ) -> RootedPlanCatalog scope planId brokerGeneration catalogId -> LifecycleEntry scope planId frame brokerGeneration VerbDown"
                        , constructors
                        )
                    ,
                        ( "the Destroy constructor privately retains its exact replay action"
                        , "CommandAuthority scope planId frame brokerGeneration VerbDestroy TeardownPhase -> IO ( Either Authority.AuthorityError (CommandAuthority scope planId frame brokerGeneration VerbDestroy TeardownPhase) ) -> RootedPlanCatalog scope planId brokerGeneration catalogId -> LifecycleEntry scope planId frame brokerGeneration VerbDestroy"
                        , constructors
                        )
                    ,
                        ( "the private replay action closes over the exact first reservation inputs"
                        , "let reauthorize = ProjectAuthority.authorizeRootProject targetRoot targetVerb targetVerified targetBound targetBinding targetLease targetPlan journal teardownCursor lifecycleContext reserved <- reauthorize"
                        , target
                        )
                    ,
                        ( "the Down entry retains that same replay action"
                        , "ProjectDown -> withReverseRootCatalog finalized root plan current lifecycleContext $ \\catalog -> use ( RootDownLifecycleEntry root verb plan lifecycleContext journal cursor authority reauthorize catalog )"
                        , sealer
                        )
                    ,
                        ( "the Destroy entry retains that same replay action"
                        , "ProjectDestroy -> withReverseRootCatalog finalized root plan current lifecycleContext $ \\catalog -> use ( RootDestroyLifecycleEntry root verb plan lifecycleContext journal cursor authority reauthorize catalog )"
                        , sealer
                        )
                    ,
                        ( "the producer accepts only the sealed entry and exact descent work"
                        , "withPreparedRootReverseDescentKernel :: LifecycleEntry scope planId rootFrame brokerGeneration verb -> DescentWork scope planId parentFrame childFrame verb"
                        , signature
                        )
                    ,
                        ( "the producer callback receives only a fresh hidden prepared descent"
                        , "forall descentId. ReverseDescent () scope planId parentFrame childFrame brokerGeneration verb descentId -> IO result"
                        , signature
                        )
                    ,
                        ( "every producer refusal returns the exact original work"
                        , "IO (Either (TeardownError, DescentWork scope planId parentFrame childFrame verb) result)"
                        , signature
                        )
                    ,
                        ( "Root Up is an unchanged-work refusal"
                        , "RootUpLifecycleEntry{} -> refused"
                        , producer
                        )
                    ,
                        ( "Child Up is an unchanged-work refusal"
                        , "ChildUpLifecycleEntry{} -> refused"
                        , producer
                        )
                    ,
                        ( "recovery child is an unchanged-work refusal"
                        , "ChildRecoveryLifecycleEntry{} -> refused"
                        , producer
                        )
                    ,
                        ( "Root Down relays only its destructured sealed package"
                        , "RootDownLifecycleEntry root verb plan lifecycleContext journal cursor authority reauthorize catalog -> prepare root verb plan catalog lifecycleContext journal cursor authority reauthorize descent use"
                        , producer
                        )
                    ,
                        ( "Root Destroy relays only its destructured sealed package"
                        , "RootDestroyLifecycleEntry root verb plan lifecycleContext journal cursor authority reauthorize catalog -> prepare root verb plan catalog lifecycleContext journal cursor authority reauthorize descent use"
                        , producer
                        )
                    ,
                        ( "the fixed bridge supplies the hidden admission token itself"
                        , "withPreparedReverseDescentKernel acquisitionJournalAdmissionKernel root verb plan catalog lifecycleContext journal cursor authority reauthorize work deliver"
                        , producer
                        )
                    ,
                        ( "the refusal contains the unchanged work and no projection"
                        , "pure ( Left ( TeardownReverseDescentRefused \"only a root Down or Destroy entry can prepare descent\" , descent ) )"
                        , refusal
                        )
                    ]
                assertFragmentsInOrder
                    "the replay closure is defined before the first reservation and retained only after success"
                    [ "let reauthorize ="
                    , "ProjectAuthority.authorizeRootProject"
                    , "targetRoot"
                    , "targetVerb"
                    , "targetVerified"
                    , "targetBound"
                    , "targetBinding"
                    , "targetLease"
                    , "targetPlan"
                    , "journal"
                    , "teardownCursor"
                    , "lifecycleContext"
                    , "reserved <- reauthorize"
                    , "case reserved of"
                    , "Right authority"
                    , "sealReverseRootEntry"
                    , "reauthorize"
                    ]
                    target
                assertFragmentsInOrder
                    "the producer exhausts Up and recovery-child refusals before the two exact root branches"
                    [ "case entry of"
                    , "RootUpLifecycleEntry{} -> refused"
                    , "ChildUpLifecycleEntry{} -> refused"
                    , "ChildRecoveryLifecycleEntry{} -> refused"
                    , "RootDownLifecycleEntry"
                    , "prepare root verb plan catalog lifecycleContext journal cursor authority reauthorize descent use"
                    , "RootDestroyLifecycleEntry"
                    , "prepare root verb plan catalog lifecycleContext journal cursor authority reauthorize descent use"
                    , "withPreparedReverseDescentKernel"
                    , "acquisitionJournalAdmissionKernel"
                    , "root"
                    , "verb"
                    , "plan"
                    , "lifecycleContext"
                    , "journal"
                    , "cursor"
                    , "authority"
                    , "reauthorize"
                    , "work"
                    , "deliver"
                    , "refused ="
                    ]
                    producer
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name producerSignature @?= 0)
                    [ "Text"
                    , "ByteString"
                    , "ProtectedStore"
                    , "RootInvocationAuthority"
                    , "ProjectVerb"
                    , "ProjectPlan"
                    , "ValidatedLifecycleContext"
                    , "AcquisitionJournal"
                    , "LifecycleCursor"
                    , "CommandAuthority"
                    , "AuthorityError"
                    , "RecordKey"
                    , "RecordVersion"
                    , "TeardownOutcome"
                    , "SubtreeSettled"
                    , "HandoffBindingInput"
                    , "HandoffChannel"
                    , "HandoffOffer"
                    , "HandoffToken"
                    , "Bool"
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name producerBody @?= 0)
                    [ "lifecycleEntryFrameName"
                    , "lifecycleEntryVerbName"
                    , "commandAuthorityInvocation"
                    , "withProtectedEntry"
                    , "readProtectedRecord"
                    , "compareAndSwapProtectedRecord"
                    , "openHandoffEdge"
                    , "registerHandoffEdge"
                    , "grantHandoff"
                    , "mkHandoffOffer"
                    , "HandoffOffer"
                    , "HandoffToken"
                    , "attemptLocalWork"
                    , "attemptPreDescentStep"
                    , "settleDescentWork"
                    , "failDescentWork"
                    , "driveTeardownForest"
                    , "verifySubtreeSettled"
                    , "verifyDestroySettled"
                    , "DestroySettled"
                    , "SubtreeSettled"
                    , "runChainFromFrame"
                    , "unsafeCoerce"
                    , "undefined"
                    , "error"
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name refusalSection @?= 0)
                    ["use", "deliver", "withPreparedReverseDescentKernel"]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name producerBody @?= 1)
                    ["withPreparedReverseDescentKernel"]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name producerBody @?= 1)
                    [ "RootUpLifecycleEntry"
                    , "ChildUpLifecycleEntry"
                    , "ChildRecoveryLifecycleEntry"
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name producerBody @?= 1)
                    [ "RootDownLifecycleEntry"
                    , "RootDestroyLifecycleEntry"
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name producerSignature @?= 0)
                    ["data", "newtype", "type"]
                SourceGuard.countHaskellIdentifier "authorizeRootProject" targetCallback @?= 1
                SourceGuard.countHaskellIdentifier "ProjectDown" producerBody @?= 0
                SourceGuard.countHaskellIdentifier "ProjectDestroy" producerBody @?= 0
                SourceGuard.countHaskellIdentifier "withPreparedRootReverseDescentKernel" entrySource @?= 4
                SourceGuard.countHaskellIdentifier "withPreparedReverseDescentKernel" entrySource @?= 3
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name entrySource @?= 0)
                    [ "lifecycleEntryReauthorize"
                    , "lifecycleEntryReauthorization"
                    , "lifecycleEntryReplay"
                    ]
                assertBool
                    "the hidden Entry surface exports its fixed producer"
                    ("withPreparedRootReverseDescentKernel" `elem` exports)
                mapM_
                    ( \name ->
                        assertBool
                            ("the hidden Entry surface exposes no constructor " <> name)
                            (name `notElem` exports)
                    )
                    [ "RootUpLifecycleEntry"
                    , "ChildUpLifecycleEntry"
                    , "ChildRecoveryLifecycleEntry"
                    , "RootDownLifecycleEntry"
                    , "RootDestroyLifecycleEntry"
                    ]
                assertBool
                    "LifecycleEntry imports the lower prepared-descent substrate"
                    (SourceGuard.importsModule "HostBootstrap.Teardown.Internal" entrySource)
                assertBool
                    "the lower substrate does not import its Entry adopter"
                    (not (SourceGuard.importsModule "HostBootstrap.Command.LifecycleEntry" internalSource))
                assertBool
                    "the lower substrate retains its public Teardown dependency"
                    (SourceGuard.importsModule "HostBootstrap.Teardown" internalSource)
                assertBool
                    "the public Command facade does not bypass the hidden Entry producer"
                    (not (SourceGuard.importsModule "HostBootstrap.Teardown.Internal" commandSource))
                SourceGuard.countHaskellIdentifier
                    "withPreparedRootReverseDescentKernel"
                    commandSource
                    @?= 0
                sources <- readProductionSources sourceRoot
                let sites name =
                        [ (moduleName, count)
                        | (moduleName, _path, sourceBody) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name sourceBody
                        , count > 0
                        ]
                    importers moduleName =
                        [ sourceModule
                        | (sourceModule, _path, sourceBody) <- sources
                        , SourceGuard.importsModule moduleName sourceBody
                        ]
                sites "withPreparedRootReverseDescentKernel"
                    @?= [("HostBootstrap.Command.LifecycleEntry", 4)]
                sites "withPreparedReverseDescentKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 3)
                        , ("HostBootstrap.Teardown.Internal", 4)
                        ]
                sites "PreparedReverseDescent"
                    @?= [("HostBootstrap.Teardown.Internal", 14)]
                sites "withVerifiedReverseAdapterKernel"
                    @?= [ ("HostBootstrap.ProjectPlan.Child.Internal", 2)
                        , ("HostBootstrap.Teardown.Internal", 3)
                        ]
                importers "HostBootstrap.Teardown.Internal"
                    @?= [ "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.Handoff.Completion"
                        , "HostBootstrap.Handoff.Process"
                        , "HostBootstrap.Handoff.Relay"
                        , "HostBootstrap.ProjectPlan.Child.Internal"
                        ]
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                modulesExporting "withPreparedRootReverseDescentKernel" publicExports @?= []
                modulesExporting "ReverseDescent" publicExports @?= []
                modulesExporting "PreparedReverseDescent" publicExports @?= []
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                librarySource <-
                    maybe
                        (assertFailure "the main library stanza is missing")
                        pure
                        (mainLibraryStanza cabalSource)
                let exposedModules = fieldModules "exposed-modules:" librarySource
                    otherModules = fieldModules "other-modules:" librarySource
                length (filter (== "HostBootstrap.Command.LifecycleEntry") otherModules) @?= 1
                length (filter (== "HostBootstrap.Teardown.Internal") otherModules) @?= 1
                mapM_
                    ( \moduleName ->
                        assertBool
                            (moduleName <> " remains hidden")
                            (moduleName `notElem` exposedModules)
                    )
                    ["HostBootstrap.Command.LifecycleEntry", "HostBootstrap.Teardown.Internal"]
                Text.count "HostBootstrap.Command.LifecycleEntry" (Text.pack cabalSource) @?= 1
                Text.count "HostBootstrap.Teardown.Internal" (Text.pack cabalSource) @?= 1
                mapM_
                    (\name -> assertAbsent "a reverse-descent producer runtime seam" name cabalSource)
                    [ "HostBootstrap.Command.LifecycleEntry.Testing"
                    , "HostBootstrap.Teardown.Testing"
                    , "HostBootstrap.Teardown.Internal.Testing"
                    ]
                assertContains
                    "the lower kernel remains token-first and opaque"
                    "{-# OPAQUE withPreparedReverseDescentKernel #-} withPreparedReverseDescentKernel admission = case Plan.consumeAcquisitionJournalAdmissionKernel admission of () -> prepareEntry"
                    internal
                assertBool
                    "the hidden Entry surface exports the prepared reverse frame service"
                    ("withPreparedRootReverseFrameServiceKernel" `elem` exports)
                assertContains
                    "prepared reverse authority keeps its root frame existentially separate from the descent parent"
                    "ValidatedLifecycleContext scope specDigest planId configId rootFrame -> AcquisitionJournal scope planId brokerGeneration -> LifecycleCursor scope planId rootFrame brokerGeneration verb phase -> CommandAuthority scope planId rootFrame brokerGeneration verb phase -> IO (Either AuthorityError (CommandAuthority scope planId rootFrame brokerGeneration verb phase)) -> DescentWork scope planId parentFrame childFrame verb"
                    internal
                mapM_
                    (\fragment -> assertBool ("the nested reverse producer omits obsolete root/parent equality: " <> fragment) (fragment `notElem` lines internalSource))
                    [ "require \"the context current frame differs\" (currentFrameId current == parent)"
                    , "require \"the cursor frame differs\" (lifecycleCursorFrame cursor == parent)"
                    , "require \"the command frame differs\" (commandAuthorityFrame retained == parent)"
                    ]
                assertFragmentsInOrder
                    "the reverse frame service retains exact state, hides pre-descent, and closes through receipt"
                    [ "withPreparedReverseForestKernel prepared (,)"
                    , "sessionRef <- newIORef opened"
                    , "offerRef <- newIORef Nothing"
                    , "complete settled"
                    , "outcome <- runPre pre"
                    , "answerNext respond prepare forestRef descentRef session successor"
                    , "case lookup (localWorkKey local) (teardownForestFailures forest) of"
                    , "Just detail -> refusedResponseWith respond session detail"
                    , "Nothing -> prepare session (localWorkKey local)"
                    , "child <- descend descentWork"
                    , "writeIORef descentRef (Just (observations, successor))"
                    , "renderPreparedReverseTerminalOriginKernel descent"
                    ]
                    (normalizeWhitespace entrySource)
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name entrySource @?= 0)
                    ["undefined", "unsafeCoerce"]
                sites "withPreparedRootReverseFrameServiceKernel"
                    @?= [("HostBootstrap.Command.LifecycleEntry", 5)]
                sites "withPreparedReverseForestKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 2)
                        , ("HostBootstrap.Teardown.Internal", 3)
                        ]
                sites "renderPreparedReverseTerminalOriginKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 2)
                        , ("HostBootstrap.Teardown.Internal", 3)
                        ]
        , testCase "ordinary lifecycle funnels refuse reverse intent while target acquisition remains available" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                modeSource <- readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Mode.hs")
                unboundEntry <-
                    requiredSourceSection
                        "ordinary unbound-lease entry"
                        "withUnboundLeaseEntry ::"
                        "{- | A lease bound to one verified plan snapshot."
                        modeSource
                boundAdmission <-
                    requiredSourceSection
                        "ordinary existing-bound admission"
                        "withBoundPlanSnapshotKernel ::"
                        "prepareExistingBoundSnapshotAt ::"
                        modeSource
                freshAllocator <-
                    requiredSourceSection
                        "central fresh broker allocator"
                        "withFreshEpoch ::"
                        "withRecordedEpoch ::"
                        modeSource
                acquisitionAdmission <-
                    requiredSourceSection
                        "ordinary acquisition journal admission"
                        "withAcquisitionJournal ::"
                        "{- | Sealed config-origin child recovery."
                        modeSource
                childReopen <-
                    requiredSourceSection
                        "authenticated live child reopen"
                        "reopenAuthenticatedChildCursorKernel ::"
                        "{- | Purely prove that a later authority gate"
                        modeSource
                profileAdmission <-
                    requiredSourceSection
                        "fresh lifecycle profile admission"
                        "consumeLifecycleProfileSlot ::"
                        "validateLifecycleProfileEvidence ::"
                        modeSource
                let mode = normalizeWhitespace modeSource
                    unbound = normalizeWhitespace unboundEntry
                    bound = normalizeWhitespace boundAdmission
                    fresh = normalizeWhitespace freshAllocator
                    acquisition = normalizeWhitespace acquisitionAdmission
                    child = normalizeWhitespace childReopen
                    profile = normalizeWhitespace profileAdmission
                mapM_
                    (\(label, fragment, source) -> assertContains label fragment source)
                    [
                        ( "unbound snapshot and bind refusal before the supplied action"
                        , "clear <- refuseReverseRootIntentForName session (leaseLocationProjectName location) case clear of Left failure -> pure (Right (Left failure)) Right () -> Right <$> action session"
                        , unbound
                        )
                    ,
                        ( "existing-bound refusal before snapshot preparation"
                        , "clear <- refuseReverseRootIntent session project case clear of Left failure -> pure (Left failure) Right () -> prepareExistingBoundSnapshotAt session location project"
                        , bound
                        )
                    ,
                        ( "fresh allocation refusal before the broker counter"
                        , "clear <- refuseReverseRootIntent session project case clear of Left failure -> pure (Left failure) Right () -> do outcome <- withFreshBrokerEpochKernel"
                        , fresh
                        )
                    ,
                        ( "migration candidate exclusion"
                        , "withProspectiveMigrationPlan session project profile oldBound _codec wire config drafts use = withOrdinaryProjectAdmission session project"
                        , mode
                        )
                    ,
                        ( "migration freeze exclusion"
                        , "withPlanMigration session project profile candidate = withOrdinaryProjectAdmission session project"
                        , mode
                        )
                    ,
                        ( "migration commit exclusion"
                        , "commitMigrationActivation session project frozen epoch = withOrdinaryProjectAdmission session project"
                        , mode
                        )
                    ,
                        ( "migration activation exclusion"
                        , "activateMigratedPlanConfigless session barrier bound epoch rehydrated = withOrdinaryProjectAdmissionForName session project proceed"
                        , mode
                        )
                    ,
                        ( "completed-migration recovery exclusion"
                        , "withCompletedMigrationRecovery session project bound use = withOrdinaryProjectAdmission session project"
                        , mode
                        )
                    ,
                        ( "invocation disposition exclusion"
                        , "writeInvocationDispositionForKey session project run disposition = withOrdinaryProjectAdmission session project"
                        , mode
                        )
                    ,
                        ( "migration marker exclusion"
                        , "recordOpenRevisionMigrationForKey session project run kind = withOrdinaryProjectAdmission session project"
                        , mode
                        )
                    ,
                        ( "terminal lease exclusion"
                        , "closeLeaseForKey session project run = withOrdinaryProjectAdmission session project"
                        , mode
                        )
                    ,
                        ( "terminal mode exclusion"
                        , "releaseMode session project expected = withOrdinaryProjectAdmission session project"
                        , mode
                        )
                    ,
                        ( "fresh Harness exclusion before its precondition callback"
                        , "withHarnessRoot store project verb preconditions swept use = do prepared <- runProtected store $ \\session -> do withOrdinaryProjectAdmission session project"
                        , mode
                        )
                    ,
                        ( "abandoned-Harness source exclusion"
                        , "abandonedHarnessLeases session project = withOrdinaryProjectAdmission session project"
                        , mode
                        )
                    ,
                        ( "abandoned-Harness reopen exclusion"
                        , "reopen run recordedSpec recordedPlan session = withOrdinaryProjectAdmission session project"
                        , mode
                        )
                    ,
                        ( "fresh profile refusal before profile-slot mutation"
                        , "clear <- refuseReverseRootIntentForName session projectName case clear of"
                        , profile
                        )
                    ,
                        ( "fresh profile mutation follows intent refusal"
                        , "Right () -> do consumed <- consumeProfileRecord session"
                        , profile
                        )
                    ]
                SourceGuard.countHaskellIdentifier "withFreshBrokerEpochKernel" freshAllocator @?= 1
                SourceGuard.countHaskellIdentifier "refuseReverseRootIntent" acquisitionAdmission @?= 0
                SourceGuard.countHaskellIdentifier "refuseReverseRootIntent" childReopen @?= 0
                assertContains
                    "ordinary acquisition retains its exact live mode/lease validator"
                    "liveResult <- validateLiveBinding session"
                    acquisition
                assertContains
                    "authenticated reopen retains its exact live mode/lease validator"
                    "reopenExistingAcquisitionCursorKernel admission store session (validateLive run expectedMode)"
                    child
        , testCase "resource and budget admission stays plan-owned and exactly indexed" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                facadeSource <- readFile (sourceRoot </> "HostBootstrap" </> "ProjectPlan.hs")
                budgetSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Cluster" </> "Budget.hs")
                exportTokens <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan"
                        facadeSource
                let facade = normalizeWhitespace facadeSource
                    budget = normalizeWhitespace budgetSource
                assertBool
                    "PlannedResource is absent from the ProjectPlan export list"
                    ("PlannedResource" `elem` exportTokens)
                assertBool
                    "PlannedResource constructors are public"
                    (not (containsTokenSequence ["PlannedResource", "("] exportTokens))
                assertRequiredMembers
                    "plan-owned resource projection exports"
                    ["withPlannedResourceOfKind", "withPlannedStepResourceOfKind"]
                    exportTokens
                mapM_
                    (\(label, fragment) -> assertContains label fragment facade)
                    [
                        ( "the exact topology projection"
                        , "topology :: ProjectPlan scope specDigest planId configId cfg -> DerivedTopology scope planId"
                        )
                    ]
                mapM_
                    (\(label, fragment) -> assertContains label fragment budget)
                    [
                        ( "the exact budget admission plan"
                        , "withValidatedBudget :: ProjectPlan scope specDigest planId configId cfg -> ResourceEnvelope ->"
                        )
                    ,
                        ( "the exact provider resource projection"
                        , "withProviderBudgetCapability :: ProjectPlan scope specDigest planId configId cfg -> PlannedResource scope planId resourceId ProviderResource frame ->"
                        )
                    ,
                        ( "the exact workload resource projection"
                        , "mkWorkload :: PlannedResource scope planId resourceId resource frame ->"
                        )
                    ,
                        ( "the exact workload topology source"
                        , "withPlannedWorkloadSet :: ProjectPlan scope specDigest planId configId cfg -> [Workload scope planId] ->"
                        )
                    ,
                        ( "the exact slice resource projection"
                        , "mkSliceRequest :: PlannedResource scope planId resourceId resource frame ->"
                        )
                    , ("plan-derived topology use", "derivedTopology = topology plan")
                    ]
                assertAbsent
                    "Budget imports or accepts the LifecyclePlan compatibility type"
                    "LifecyclePlan"
                    budgetSource
                assertBool
                    "Budget imports the hidden lifecycle-plan representation kernel"
                    (not (SourceGuard.importsModule "HostBootstrap.Lifecycle.Plan" budgetSource))
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                let constructorExporters =
                        sort
                            [ moduleName
                            | (moduleName, exports) <- publicExports
                            , containsTokenSequence ["PlannedResource", "("] exports
                            ]
                constructorExporters @?= []
                mapM_
                    ( \producer ->
                        modulesExporting producer publicExports
                            @?= ["HostBootstrap.ProjectPlan"]
                    )
                    [ "withPlannedResourceOfKind"
                    , "withPlannedEdge"
                    , "withProviderGuestAliasProjection"
                    , "withPlannedStepResourceOfKind"
                    , "withPlannedStepGuestAliasProjection"
                    ]
        , testCase "Production commands admit exactly one fresh or recovered plan identity" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                commandSource <- readFile (sourceRoot </> "HostBootstrap" </> "Command.hs")
                let command = commandSource
                freshAdmission <-
                    requiredSourceSection
                        "fresh Production plan admission"
                        "withFreshProductionPlan store root validated ctx verb use = do"
                        "withRecoveredProductionPlan ::"
                        command
                recoveredAdmission <-
                    requiredSourceSection
                        "recovered Production plan admission"
                        "withRecoveredProductionPlan store root candidateConfig ctx use ="
                        "startsFreshProductionInvocation ::"
                        command
                upCommand <-
                    requiredSourceSection
                        "project up command"
                        "runUp dryRun ="
                        "failChain ::"
                        command
                teardownCommand <-
                    requiredSourceSection
                        "Production teardown command"
                        "runProductionTeardown root validated ctx cfg verb = do"
                        "reverseProjection ::"
                        command

                SourceGuard.countHaskellIdentifier "withProjectPlan" freshAdmission @?= 1
                SourceGuard.countHaskellIdentifier "withCurrentFrame" freshAdmission @?= 1
                SourceGuard.countHaskellIdentifier "withRecoveredProductionProjectPlanInputs" recoveredAdmission @?= 1
                SourceGuard.countHaskellIdentifier "withRecoveredProductionProjectPlan" recoveredAdmission @?= 1
                SourceGuard.countHaskellIdentifier "withCurrentFrame" recoveredAdmission @?= 1
                SourceGuard.countHaskellIdentifier "withProjectPlan" recoveredAdmission @?= 0
                SourceGuard.countHaskellIdentifier "withRecoveredProductionPlan" upCommand @?= 1
                SourceGuard.countHaskellIdentifier "withFreshProductionPlan" upCommand @?= 1
                SourceGuard.countHaskellIdentifier "withRootProjectReverseLifecycleEntry" teardownCommand @?= 1
                SourceGuard.countHaskellIdentifier "runRootProjectReverseLifecycleEntry" teardownCommand @?= 1
                SourceGuard.countHaskellIdentifier "localWorkOperationKey" teardownCommand @?= 1
                SourceGuard.countHaskellIdentifier "verifyProjectChartResourceRecordBundle" teardownCommand @?= 1
                SourceGuard.countHaskellIdentifier "runVerifiedChartWorkloadCleanupCall" teardownCommand @?= 1
                SourceGuard.countHaskellIdentifier "PlanExecutionPackage" teardownCommand @?= 0
                SourceGuard.countHaskellIdentifier "withRecoveredProductionPlan" teardownCommand @?= 0
                SourceGuard.countHaskellIdentifier "withFreshProductionPlan" teardownCommand @?= 0
        , testCase "descriptive context and nominal authorities retain broker continuity" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                frameSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Frame.hs")
                sessionSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Session.hs")
                authorityKernelSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Authority" </> "Kernel.hs")
                projectAuthoritySource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Authority" </> "ProjectPlan.hs")
                childSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Child" </> "Internal.hs")
                entrySource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Command" </> "LifecycleEntry.hs")
                let frame = normalizeWhitespace frameSource
                    session = normalizeWhitespace sessionSource
                    authorityKernel = normalizeWhitespace authorityKernelSource
                    projectAuthority = normalizeWhitespace projectAuthoritySource
                    child = normalizeWhitespace childSource
                    entry = normalizeWhitespace entrySource
                mapM_
                    (\(label, fragment, source) -> assertContains label fragment source)
                    [
                        ( "the exact descriptive context indices"
                        , "newtype ValidatedContext scope planId frame = ValidatedContext Context.BinaryContext"
                        , frame
                        )
                    ,
                        ( "the descriptive context's nominal roles"
                        , "type role ValidatedContext nominal nominal nominal"
                        , frame
                        )
                    ,
                        ( "the acquisition journal indices"
                        , "data AcquisitionJournal scope planId brokerGeneration where"
                        , session
                        )
                    ,
                        ( "the acquisition journal's nominal roles"
                        , "type role AcquisitionJournal nominal nominal nominal"
                        , session
                        )
                    ,
                        ( "the lifecycle cursor indices"
                        , "data LifecycleCursor scope planId frame brokerGeneration verb phase where"
                        , session
                        )
                    ,
                        ( "the lifecycle cursor's nominal roles"
                        , "type role LifecycleCursor nominal nominal nominal nominal nominal nominal"
                        , session
                        )
                    ,
                        ( "the command authority indices"
                        , "data CommandAuthority scope planId frame brokerGeneration verb phase"
                        , authorityKernel
                        )
                    ,
                        ( "the command authority's nominal roles"
                        , "type role CommandAuthority nominal nominal nominal nominal nominal nominal"
                        , authorityKernel
                        )
                    ,
                        ( "the journal broker carried into root admission"
                        , "AcquisitionJournal scope planId brokerGeneration -> LifecycleCursor scope planId frame brokerGeneration verb phase -> ValidatedLifecycleContext"
                        , projectAuthority
                        )
                    ,
                        ( "the authenticated child's authorized package"
                        , "data AuthorizedChildCursor scope specDigest planDigest brokerGeneration parentFrame planId configId childFrame verb phase"
                        , child
                        )
                    ,
                        ( "the authorized child's ten nominal roles"
                        , "type role AuthorizedChildCursor nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal"
                        , child
                        )
                    ,
                        ( "the authorized package's Teardown successor"
                        , "AuthorizedTeardownChildCursor :: AuthorizedChildCursor"
                        , child
                        )
                    ,
                        ( "the child entry retains one inseparable authorized package"
                        , "ChildUpLifecycleEntry :: AuthorizedChildCursor scope specDigest planDigest brokerGeneration parentFrame planId configId frame VerbUp ExecutePhase -> LifecycleEntry"
                        , entry
                        )
                    ]
                SourceGuard.countHaskellIdentifier "authorizeChildProject" projectAuthoritySource @?= 0
                SourceGuard.countHaskellIdentifier "childCommandReservationKernel" childSource @?= 3
                Text.count
                    "AuthorizedTeardownChildCursor authorized teardownCursor"
                    (Text.pack childSource)
                    @?= 1
        , testCase "authenticated child cursor recovery stays token-gated and coordinate-free" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                sessionSource <- readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Session.hs")
                modeSource <- readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Mode.hs")
                childSource <- readFile (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Child" </> "Internal.hs")
                sessionBridge <-
                    requiredSourceSection
                        "existing-only child acquisition bridge"
                        "reopenExistingAcquisitionCursorKernel ::"
                        "requireChildCursorPresence ::"
                        sessionSource
                modeBridge <-
                    requiredSourceSection
                        "one-entry authenticated child bridge"
                        "reopenAuthenticatedChildCursorKernel ::"
                        "{- | Reopen one authenticated recovery child's existing reverse cursor."
                        modeSource
                let session = normalizeWhitespace sessionBridge
                    mode = normalizeWhitespace modeBridge
                    child = normalizeWhitespace childSource
                mapM_
                    (\(label, fragment, source) -> assertContains label fragment source)
                    [
                        ( "the existing-only acquisition lookup"
                        , "Right Nothing -> pure (Left (SessionAcquisitionMissing (recordKeyText recordKey)))"
                        , session
                        )
                    ,
                        ( "the child request bound check"
                        , "case validateLifecycleCursorRequest journal frame ProjectUp of"
                        , session
                        )
                    ,
                        ( "the Prepare-only absent cursor policy"
                        , "lifecyclePhaseName requestedPhase == lifecyclePhaseName Prepare"
                        , normalizeWhitespace sessionSource
                        )
                    ,
                        ( "the hidden token is forced before retained evidence"
                        , "case consumeAcquisitionJournalAdmissionKernel admission of () -> case retainedEvidence of"
                        , mode
                        )
                    ,
                        ( "the acquisition lease key is checked before its read"
                        , "case requireText \"lease key\" canonicalLease leaseText of Left failure -> pure (Left failure) Right () -> do modeResult <- readRequired session (\"mode.\" <> project) \"project mode\" leaseResult <- readRequired session canonicalLease \"run lease\""
                        , mode
                        )
                    ,
                        ( "the callback follows the protected entry"
                        , "Right (Right (journal, cursor)) -> Right <$> use journal cursor"
                        , mode
                        )
                    ,
                        ( "the child authority retains its exact phase"
                        , "ChildPlanAuthority :: HandoffBinding scope brokerGeneration -> LifecyclePhase phase ->"
                        , child
                        )
                    ,
                        ( "the signed child identity remains distinct from the local frame"
                        , "parentFrame signedChildFrame configId VerbUp phase"
                        , child
                        )
                    ,
                        ( "the child package's ten nominal roles"
                        , "type role AuthenticatedChildCursor nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal"
                        , child
                        )
                    ,
                        ( "nested lifecycle context is mandatory"
                        , "withValidatedNestedLifecycleContext lifecycleContext"
                        , child
                        )
                    ]
                SourceGuard.countHaskellIdentifier "compareAndSwapProtectedRecord" sessionBridge @?= 0
                SourceGuard.countHaskellIdentifier "withProtectedEntry" modeBridge @?= 1
                SourceGuard.countHaskellIdentifier "unsafeCoerce" childSource @?= 0
                SourceGuard.countHaskellIdentifier "withAuthenticatedChildCursorEvidence" childSource @?= 0
        , testCase "reverse child recovery is existing-only, exact, and callback-safe" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                sessionSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Session.hs")
                modeSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Mode.hs")
                sessionTesting <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Session" </> "Testing.hs")
                configOpener <-
                    requiredSourceSection
                        "config-origin existing acquisition opener"
                        "reopenExistingAcquisitionCursorKernel ::"
                        "{- | Strict existing-only admission for one authenticated reverse child."
                        sessionSource
                reverseOpener <-
                    requiredSourceSection
                        "strict reverse acquisition opener"
                        "{- | Strict existing-only admission for one authenticated reverse child."
                        "reopenExistingAcquisitionJournalInEntry ::"
                        sessionSource
                existingHelper <-
                    requiredSourceSection
                        "shared existing acquisition helper"
                        "reopenExistingAcquisitionJournalInEntry ::"
                        "requireChildCursorPresence ::"
                        sessionSource
                targetCursor <-
                    requiredSourceSection
                        "refactored reverse target cursor"
                        "withReverseRootTargetLifecycleCursorKernel ::"
                        "{- | Open or exactly resume one frame-local cursor."
                        sessionSource
                configWrapper <-
                    requiredSourceSection
                        "config-origin authenticated child wrapper"
                        "reopenAuthenticatedChildCursorKernel ::"
                        "{- | Reopen one authenticated recovery child's existing reverse cursor."
                        modeSource
                recoveryWrapper <-
                    requiredSourceSection
                        "authenticated reverse child wrapper"
                        "{- | Reopen one authenticated recovery child's existing reverse cursor."
                        "{- | Purely prove that a later authority gate"
                        modeSource
                let config = normalizeWhitespace configOpener
                    reverseJournal = normalizeWhitespace reverseOpener
                    existing = normalizeWhitespace existingHelper
                    target = normalizeWhitespace targetCursor
                    configMode = normalizeWhitespace configWrapper
                    recovery = normalizeWhitespace recoveryWrapper
                mapM_
                    (\(label, fragment, body) -> assertContains label fragment body)
                    [
                        ( "config recovery remains statically Up-indexed"
                        , "LifecycleCursor scope planId frame brokerGeneration VerbUp phase"
                        , config
                        )
                    ,
                        ( "config recovery factors through the shared existing-row helper"
                        , "reopenExistingAcquisitionJournalInEntry store session validateLive stableScope project storeId snapshot run spec epoch (projectVerbName ProjectUp) Nothing"
                        , config
                        )
                    ,
                        ( "config recovery validates and opens only ProjectUp"
                        , "validateLifecycleCursorRequest journal frame ProjectUp"
                        , config
                        )
                    ,
                        ( "config recovery opens only the requested existing Up cursor"
                        , "openLifecycleCursorInEntry session journal frame ProjectUp phase"
                        , config
                        )
                    ,
                        ( "the reverse opener takes the hidden admission first"
                        , "reopenExistingReverseAcquisitionJournalKernel :: AcquisitionJournalAdmission -> ProtectedStore -> ProtectedSession session"
                        , reverseJournal
                        )
                    ,
                        ( "the reverse opener returns only the exact journal"
                        , "ProjectVerb verb -> IO (Either SessionError (AcquisitionJournal scope planId brokerGeneration))"
                        , reverseJournal
                        )
                    ,
                        ( "the reverse opener is strict and opaque on partial application"
                        , "{-# OPAQUE reopenExistingReverseAcquisitionJournalKernel #-} reopenExistingReverseAcquisitionJournalKernel admission = case consumeAcquisitionJournalAdmissionKernel admission of () -> \\store session validateLive stableScope project storeId snapshot run spec epoch frame verb ->"
                        , reverseJournal
                        )
                    ,
                        ( "reverse acquisition requires the immutable Prepare/version-one seed"
                        , "run spec epoch verbName (Just (\"prepare\", 1))"
                        , reverseJournal
                        )
                    ,
                        ( "reverse acquisition totally refuses Up"
                        , "ProjectUp -> pure (Left (SessionCursorVerbMismatch \"down or destroy\" \"up\"))"
                        , reverseJournal
                        )
                    ,
                        ( "Down validates its exact typed frame and verb"
                        , "ProjectDown -> do opened <- reopen (projectVerbName verb) pure $ opened >>= \\journal -> journal <$ validateLifecycleCursorRequest journal frame verb"
                        , reverseJournal
                        )
                    ,
                        ( "Destroy validates its exact typed frame and verb"
                        , "ProjectDestroy -> do opened <- reopen (projectVerbName verb) pure $ opened >>= \\journal -> journal <$ validateLifecycleCursorRequest journal frame verb"
                        , reverseJournal
                        )
                    ,
                        ( "the shared helper derives the one existing acquisition key"
                        , "either (pure . Left) reopen (childAcquisitionKey project run epoch)"
                        , existing
                        )
                    ,
                        ( "absence is a hard existing-row refusal"
                        , "Right Nothing -> pure (Left (SessionAcquisitionMissing (recordKeyText recordKey)))"
                        , existing
                        )
                    ,
                        ( "the durable acquisition row must re-encode canonically"
                        , "protectedRecordBytes record /= encodeAcquisitionRecord binding seed"
                        , existing
                        )
                    ,
                        ( "the durable verb and complete binding are exact"
                        , "acquisitionBindingRootVerb binding /= verbName"
                        , existing
                        )
                    ,
                        ( "the reverse seed requirement is checked before liveness"
                        , "Just (requiredSeed, _) <- required , acquisitionPhaseText seed /= requiredSeed"
                        , existing
                        )
                    ,
                        ( "the reverse record version requirement is checked before liveness"
                        , "Just (_, requiredVersion) <- required , recordVersionWord (protectedRecordVersion record) /= requiredVersion"
                        , existing
                        )
                    ,
                        ( "the exact retained liveness validator precedes journal construction"
                        , "valid <- check session pure $ case valid of Left failure -> Left failure Right () -> Right ( AcquisitionJournal store check recordKey (protectedRecordVersion record) binding seed )"
                        , existing
                        )
                    ,
                        ( "the target cursor is strict and opaque"
                        , "{-# OPAQUE withReverseRootTargetLifecycleCursorKernel #-} withReverseRootTargetLifecycleCursorKernel admission = case consumeAcquisitionJournalAdmissionKernel admission of () -> \\journal@(AcquisitionJournal store validateLive _ sourceVersion _ seedPhase) frame verb use ->"
                        , target
                        )
                    ,
                        ( "target retained liveness is checked before the current cursor"
                        , "inLifecycleCursorEntry store $ \\session -> do live <- validateLive session case live of Left failure -> pure (Left failure) Right () -> do current <- openCurrentLifecycleCursorInEntry session Nothing journal frame verb"
                        , target
                        )
                    ,
                        ( "the target callback follows the protected-entry result"
                        , "either (pure . Left) (fmap Right . use) terminal"
                        , target
                        )
                    ,
                        ( "config-origin Mode admission remains narrowed-config only"
                        , "require \"payload kind\" (handoffPayloadKind signed == NarrowedProjectConfig)"
                        , configMode
                        )
                    ,
                        ( "config-origin Mode admission retains exact config bytes identity"
                        , "requireText \"configuration digest\" configDigest (handoffChildConfigDigest signed)"
                        , configMode
                        )
                    ,
                        ( "the recovery wrapper accepts only typed retained evidence"
                        , "reopenAuthenticatedRecoveryChildCursorKernel :: AcquisitionJournalAdmission -> ProtectedStore -> HandoffBinding scope brokerGeneration -> ProjectPlan scope specDigest planId configId cfg -> PlanDigestBinding scope specDigest planDigest planId -> ProjectFrame scope specDigest planId configId frame -> ProjectVerb verb"
                        , recovery
                        )
                    ,
                        ( "the recovery wrapper yields only the exact journal/cursor pair"
                        , "AcquisitionJournal scope planId brokerGeneration -> LifecycleCursor scope planId frame brokerGeneration verb TeardownPhase -> IO result"
                        , recovery
                        )
                    ,
                        ( "the recovery wrapper is strict and opaque"
                        , "{-# OPAQUE reopenAuthenticatedRecoveryChildCursorKernel #-} reopenAuthenticatedRecoveryChildCursorKernel admission = case consumeAcquisitionJournalAdmissionKernel admission of () -> \\store signed plan binding frame verb use ->"
                        , recovery
                        )
                    ,
                        ( "recovery accepts only the authenticated adapter payload"
                        , "require \"payload kind\" (handoffPayloadKind signed == RecoveryAdapterWire)"
                        , recovery
                        )
                    ,
                        ( "the adapter coordinate is canonical lower hexadecimal"
                        , "require \"adapter digest coordinate\" $ Text.length adapterDigest == 64 && Text.all lowerHex adapterDigest"
                        , recovery
                        )
                    ,
                        ( "the exact local topology supplies one parent-child edge"
                        , "[ edge | edge@(_, edgeChild) <- topologyParentEdges (topology plan) , edgeChild == child ] == [(parent, child)]"
                        , recovery
                        )
                    ,
                        ( "only a version-two committed intent can be admitted"
                        , "recordVersionWord (protectedRecordVersion record) /= 2"
                        , recovery
                        )
                    ,
                        ( "Down committed intent is the exact admitted branch"
                        , "ReverseRootDownCommitted common target modeVersion modeBytes leaseVersion leaseBytes"
                        , recovery
                        )
                    ,
                        ( "Destroy committed intent is the exact admitted branch"
                        , "ReverseRootDestroyCommitted common target modeVersion modeBytes leaseVersion leaseBytes"
                        , recovery
                        )
                    ,
                        ( "both Pending states refuse as Pending"
                        , "ReverseRootDownPending{} -> pure (mismatch \"reverse-root intent state\" \"committed\" \"pending\") Just ReverseRootDestroyPending{} -> pure (mismatch \"reverse-root intent state\" \"committed\" \"pending\")"
                        , recovery
                        )
                    ,
                        ( "the exact local canonical plan is independently rendered"
                        , "canonical = projectPlanCanonicalSnapshotKernel plan"
                        , recovery
                        )
                    ,
                        ( "committed intent retains exact config and canonical plan independently"
                        , "requireText \"intent configuration\" configDigest intentConfig requireText \"intent plan\" planDigest intentPlan requireBytes \"intent canonical plan\" canonicalBytes intentCanonical"
                        , recovery
                        )
                    ,
                        ( "live intent, mode, lease, and snapshot rows are all reread"
                        , "intentResult <- readRequired intentKey \"reverse-root intent\" modeResult <- readNamed (\"mode.\" <> project) \"project mode\" leaseResult <- readNamed canonicalLease \"run lease\" snapshotResult <- readNamed (\"snapshot.\" <> project <> \".\" <> run) \"plan snapshot\""
                        , recovery
                        )
                    ,
                        ( "the existing reverse journal is opened inside the protected entry"
                        , "reopenExistingReverseAcquisitionJournalKernel admission store session"
                        , recovery
                        )
                    ,
                        ( "journal liveness reruns the complete row validator"
                        , "Right () -> validateRowsAt live"
                        , recovery
                        )
                    ,
                        ( "the target cursor and callback follow the committed-entry unlock"
                        , "Right (Right journal) -> withReverseRootTargetLifecycleCursorKernel admission journal frame verb (use journal)"
                        , recovery
                        )
                    ,
                        ( "Mode totally refuses recovery Up"
                        , "ProjectUp -> pure (Left (SessionCursorVerbMismatch \"down/destroy\" \"up\"))"
                        , recovery
                        )
                    ]
                assertFragmentsInOrder
                    "the shared helper reads, validates, checks liveness, then constructs"
                    [ "childAcquisitionKey project run epoch"
                    , "readProtectedRecord session recordKey"
                    , "Right Nothing"
                    , "decodeAcquisitionRecord"
                    , "encodeAcquisitionRecord binding seed"
                    , "acquisitionBindingRootVerb binding"
                    , "binding /= expectedBinding binding"
                    , "acquisitionPhaseText seed"
                    , "recordVersionWord (protectedRecordVersion record)"
                    , "valid <- check session"
                    , "Right ()"
                    , "AcquisitionJournal"
                    ]
                    existing
                assertFragmentsInOrder
                    "Mode authenticates, locks, defines exact row validation, dispatches committed intent, unlocks, then drives the target"
                    [ "retainedEvidence"
                    , "RecoveryAdapterWire"
                    , "adapter digest coordinate"
                    , "reverseRootIntentKeyForName project"
                    , "withProtectedEntry store"
                    , "validateRowsAt session"
                    , "reopenExistingReverseAcquisitionJournalKernel"
                    , "observed <- readProtectedRecord session intentKey"
                    , "ReverseRootDownCommitted"
                    , "ReverseRootDestroyCommitted"
                    , "case entered of"
                    , "Right (Right journal)"
                    , "withReverseRootTargetLifecycleCursorKernel"
                    , "use journal"
                    ]
                    recovery
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name existingHelper @?= 0)
                    [ "compareAndSwapProtectedRecord"
                    , "ExpectAbsent"
                    , "writeProtectedRecord"
                    , "withProtectedEntry"
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name reverseOpener @?= 0)
                    ["use", "result", "withProtectedEntry", "compareAndSwapProtectedRecord", "ExpectAbsent"]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name configOpener @?= 0)
                    ["ProjectDown", "ProjectDestroy", "RecoveryAdapterWire", "compareAndSwapProtectedRecord"]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name recoveryWrapper @?= 0)
                    [ "ReceivedRecoveryDescent"
                    , "withVerifiedReverseAdapterKernel"
                    , "renderReverseAdapter"
                    , "CommandAuthority"
                    , "LifecycleEntry"
                    , "reserveCurrentLifecycleCommandKernel"
                    , "runChainFromFrame"
                    , "openHandoffEdge"
                    , "registerHandoffEdge"
                    , "HandoffOffer"
                    , "HandoffToken"
                    , "attemptLocalWork"
                    , "attemptPreDescentStep"
                    , "settleDescentWork"
                    , "failDescentWork"
                    , "driveTeardownForest"
                    , "verifySubtreeSettled"
                    , "DestroySettled"
                    , "SubtreeSettled"
                    , "unsafeCoerce"
                    , "undefined"
                    , "error"
                    , "compareAndSwapProtectedRecord"
                    , "ExpectAbsent"
                    ]
                mapM_
                    (\section -> mapM_ (\name -> SourceGuard.countHaskellIdentifier name section @?= 0) ["data", "newtype", "type"])
                    [reverseOpener, existingHelper, targetCursor, recoveryWrapper]
                SourceGuard.countHaskellIdentifier "reopenExistingAcquisitionJournalInEntry" configOpener @?= 1
                SourceGuard.countHaskellIdentifier "reopenExistingAcquisitionJournalInEntry" reverseOpener @?= 1
                SourceGuard.countHaskellIdentifier "withProtectedEntry" recoveryWrapper @?= 1
                SourceGuard.countHaskellIdentifier "reopenExistingReverseAcquisitionJournalKernel" recoveryWrapper @?= 1
                SourceGuard.countHaskellIdentifier "withReverseRootTargetLifecycleCursorKernel" recoveryWrapper @?= 1
                SourceGuard.countHaskellIdentifier "handoffChildConfigDigest" recoveryWrapper @?= 1
                assertAbsent
                    "adapter digest is not equated to the local configuration digest"
                    "requireText \"configuration digest\" configDigest (handoffChildConfigDigest signed)"
                    recovery
                SourceGuard.countHaskellIdentifier "ReceivedRecoveryDescent" modeSource @?= 0
                assertBool
                    "Mode does not import the future Teardown.Internal verifier"
                    (not (SourceGuard.importsModule "HostBootstrap.Teardown.Internal" modeSource))
                sources <- readProductionSources sourceRoot
                let sites name =
                        [ (moduleName, count)
                        | (moduleName, _path, sourceBody) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name sourceBody
                        , count > 0
                        ]
                sites "reopenExistingAcquisitionJournalInEntry"
                    @?= [("HostBootstrap.Lifecycle.Session", 4)]
                sites "reopenExistingReverseAcquisitionJournalKernel"
                    @?= [ ("HostBootstrap.Lifecycle.Mode", 2)
                        , ("HostBootstrap.Lifecycle.Session", 4)
                        ]
                sites "reopenAuthenticatedRecoveryChildCursorKernel"
                    @?= [ ("HostBootstrap.Lifecycle.Mode", 4)
                        , ("HostBootstrap.ProjectPlan.Child.Internal", 2)
                        ]
                sites "withReverseRootTargetLifecycleCursorKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 3)
                        , ("HostBootstrap.Lifecycle.Mode", 2)
                        , ("HostBootstrap.Lifecycle.Session", 4)
                        ]
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                modulesExporting "reopenExistingReverseAcquisitionJournalKernel" publicExports
                    @?= ["HostBootstrap.Lifecycle.Session"]
                modulesExporting "reopenAuthenticatedRecoveryChildCursorKernel" publicExports
                    @?= ["HostBootstrap.Lifecycle.Mode"]
                modulesExporting "AcquisitionJournalAdmission" publicExports @?= []
                SourceGuard.countHaskellIdentifier
                    "reopenExistingReverseAcquisitionJournalKernel"
                    sessionTesting
                    @?= 0
                SourceGuard.countHaskellIdentifier
                    "reopenAuthenticatedRecoveryChildCursorKernel"
                    sessionTesting
                    @?= 0
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                librarySource <-
                    maybe
                        (assertFailure "the main library stanza is missing")
                        pure
                        (mainLibraryStanza cabalSource)
                let exposedModules = fieldModules "exposed-modules:" librarySource
                    otherModules = fieldModules "other-modules:" librarySource
                length (filter (== "HostBootstrap.Lifecycle.Session") exposedModules) @?= 1
                length (filter (== "HostBootstrap.Lifecycle.Mode") exposedModules) @?= 1
                assertBool
                    "no reverse-recovery testing module was registered"
                    ( "HostBootstrap.Lifecycle.Mode.Testing" `notElem` otherModules
                        && "HostBootstrap.Lifecycle.Recovery.Testing" `notElem` otherModules
                    )
        , testCase "recovery child origin is sealed and locally derived" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                authorityInternalSource <-
                    readFile
                        ( sourceRoot
                            </> "HostBootstrap"
                            </> "Authority"
                            </> "ProjectPlan"
                            </> "Internal.hs"
                        )
                childSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Child" </> "Internal.hs")
                entrySource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Command" </> "LifecycleEntry.hs")
                constructSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Construct.hs")
                originSchema <-
                    requiredSourceSection
                        "sealed recovery-child origin schema"
                        "data ChildRecoveryOrigin"
                        "withChildRecoveryOriginKernel ::"
                        authorityInternalSource
                originSealer <-
                    requiredSourceSection
                        "fixed-unit recovery-child origin sealer"
                        "withChildRecoveryOriginKernel ::"
                        "-- | Descriptive local frame"
                        authorityInternalSource
                let terminalSource =
                        unlines
                            ( dropWhile
                                (not . isPrefixOf "withChildRecoveryTerminalOriginKernel ::")
                                (lines authorityInternalSource)
                            )
                    producerSource =
                        unlines
                            ( dropWhile
                                (not . isPrefixOf "withReceivedRecoveryChildOriginKernel ::")
                                (lines childSource)
                            )
                assertBool "the recovery terminal fold source marker is missing" (not (null terminalSource))
                assertBool "the recovery child producer source marker is missing" (not (null producerSource))
                originExports <-
                    requiredModuleExports
                        "HostBootstrap.Authority.ProjectPlan.Internal"
                        authorityInternalSource
                filter (/= ",") originExports
                    @?= [ "ChildRecoveryOrigin"
                        , "withChildRecoveryOriginKernel"
                        , "childRecoveryOriginFrameNameKernel"
                        , "childRecoveryOriginVerbNameKernel"
                        , "withChildRecoveryTerminalOriginKernel"
                        ]
                let origin = normalizeWhitespace authorityInternalSource
                    schema = normalizeWhitespace originSchema
                    sealer = normalizeWhitespace originSealer
                    terminal = normalizeWhitespace terminalSource
                    producer = normalizeWhitespace producerSource
                mapM_
                    (\(label, fragment, body) -> assertContains label fragment body)
                    [
                        ( "the recovery origin has exactly nine retained indices"
                        , "data ChildRecoveryOrigin scope specDigest planDigest brokerGeneration parentFrame planId configId childFrame verb where"
                        , origin
                        )
                    ,
                        ( "the recovery origin's nine roles are all nominal"
                        , "type role ChildRecoveryOrigin nominal nominal nominal nominal nominal nominal nominal nominal nominal"
                        , schema
                        )
                    ,
                        ( "the origin existentially retains the signed remote child"
                        , "ReceivedRecoveryDescent scope brokerGeneration planDigest parentFrame signedChildFrame recoveryWireDigest recoveryWireId verb"
                        , schema
                        )
                    ,
                        ( "the origin jointly retains the independently admitted local package"
                        , "ProjectPlan scope specDigest planId configId cfg -> PlanDigestBinding scope specDigest planDigest planId -> ValidatedLifecycleContext scope specDigest planId configId childFrame -> TeardownPlan scope planId childFrame verb -> AcquisitionJournal scope planId brokerGeneration -> LifecycleCursor scope planId childFrame brokerGeneration verb TeardownPhase -> CommandAuthority scope planId childFrame brokerGeneration verb TeardownPhase"
                        , schema
                        )
                    ,
                        ( "the origin sealer fixes both callback and outer results to unit"
                        , "ChildRecoveryOrigin scope specDigest planDigest brokerGeneration parentFrame planId configId childFrame verb -> IO (Either Text ()) ) -> IO (Either Text ())"
                        , sealer
                        )
                    ,
                        ( "the sealer fully eliminates the received package before retaining anything"
                        , "withReceivedRecoveryDescent descent $ \\_ _ _ _ _ _ ->"
                        , sealer
                        )
                    ,
                        ( "the sealer forces every independently admitted local term"
                        , "plan `seq` binding `seq` context `seq` teardown `seq` journal `seq` cursor `seq` authority `seq` use ( ChildRecoveryOrigin descent plan binding context teardown journal cursor authority )"
                        , sealer
                        )
                    ,
                        ( "the only origin views are descriptive frame and closed verb text"
                        , "childRecoveryOriginFrameNameKernel (ChildRecoveryOrigin _ _ _ _ _ _ _ authority) = commandAuthorityFrame authority"
                        , origin
                        )
                    ,
                        ( "the descriptive verb view retains the closed command term"
                        , "childRecoveryOriginVerbNameKernel (ChildRecoveryOrigin _ _ _ _ _ _ _ authority) = projectVerbName (commandAuthorityVerb authority)"
                        , origin
                        )
                    ,
                        ( "the terminal fold gives its callback canonical bytes only"
                        , "(ByteString.ByteString -> IO (Either Text ())) -> IO (Either Text ())"
                        , terminal
                        )
                    ,
                        ( "the terminal fold re-eliminates the complete received package"
                        , "withReceivedRecoveryDescent descent $ \\edge _ verb adapter _ _ ->"
                        , terminal
                        )
                    ,
                        ( "the terminal identity is one length-framed canonical byte stream"
                        , "use . ByteString.concat . map frameWire $ [ \"child-recovery-terminal-origin-v1\" , \"1\" , renderHandoffBinding (verifiedHandoffBinding (receivedEdgeHandoff edge))"
                        , terminal
                        )
                    ,
                        ( "the terminal identity closes over local plan, reservation, cursor, frame, verb, and adapter digest"
                        , "text (stablePlanSnapshotDigest (renderSnapshot plan)) , text (planDigestBindingDigestKernel digestBinding) , text (invocationIdText (commandAuthorityInvocation authority)) , word (acquisitionJournalRecordVersion journal) , word (lifecycleCursorRecordVersion cursor) , text (commandAuthorityFrame authority) , word (brokerEpochWord (commandAuthorityEpoch authority)) , text (projectVerbName verb) , text (projectVerbName (commandAuthorityVerb authority)) , text (lifecyclePhaseName (commandAuthorityPhase authority)) , text (teardownPlanFrameId teardown) , text (teardownPlanVerbName teardown) , text (recoveryWireDigest adapter)"
                        , terminal
                        )
                    ,
                        ( "the child producer fixes fresh local plan and frame identities"
                        , "( forall localPlanId localFrame. ChildRecoveryOrigin scope specDigest planDigest brokerGeneration parentFrame localPlanId configId localFrame verb -> IO (Either Text.Text ()) ) -> IO (Either Text.Text ())"
                        , producer
                        )
                    ,
                        ( "the producer is opaque and forces the received package before caller inputs"
                        , "{-# OPAQUE withReceivedRecoveryChildOriginKernel #-} withReceivedRecoveryChildOriginKernel descent = case descent `seq` () of () -> \\store root config drafts binaryContext use ->"
                        , producer
                        )
                    ,
                        ( "the received envelope is Recovery-only, Production, and Teardown"
                        , "require \"payload kind\" (handoffPayloadKind signed == RecoveryAdapterWire) requireText \"scope\" \"Production\" (handoffScope signed) requireText \"phase\" \"teardown\" (handoffPhase signed)"
                        , producer
                        )
                    ,
                        ( "the received verb is totally classified before plan admission"
                        , "case verb of ProjectUp -> mismatch \"verb\" \"down or destroy\" \"up\" ProjectDown -> requireText \"verb\" \"down\" (handoffVerb signed) ProjectDestroy -> requireText \"verb\" \"destroy\" (handoffVerb signed)"
                        , producer
                        )
                    ,
                        ( "the full received payload is checked before use"
                        , "require \"token commitment\" (not (Text.null (handoffTokenCommitment signed))) require \"adapter\" (not (ByteString.null adapter)) require \"projection\" (not (ByteString.null projection)) require \"grant\" (not (ByteString.null grant))"
                        , producer
                        )
                    ,
                        ( "the authenticated adapter digest is canonical lower hexadecimal"
                        , "requireText \"adapter digest\" (handoffChildConfigDigest signed) (recoveryWireDigest adapter) require \"adapter digest coordinate\" $ Text.length (handoffChildConfigDigest signed) == 64 && Text.all lowerHex (handoffChildConfigDigest signed)"
                        , producer
                        )
                    ,
                        ( "the local executable plan is independently admitted from typed drafts"
                        , "withChildProjectPlanKernel \"production\" (handoffBrokerGeneration signed) (handoffInstalledProject signed) (handoffStoreIdentity signed) (handoffPlanRevision signed) config drafts"
                        , producer
                        )
                    ,
                        ( "the local plan is rechecked against authenticated origin and local config"
                        , "requireText \"plan specification digest\" (handoffSpecDigest signed) (stablePlanSnapshotSpecDigest snapshot) requireText \"plan configuration digest\" (validatedConfigDigest config) (stablePlanSnapshotConfigDigest snapshot) requireText \"stable plan digest\" (handoffPlanRevision signed) planDigest"
                        , producer
                        )
                    ,
                        ( "the local plan and context mint the fresh local frame"
                        , "withValidatedLifecycleContext root store plan binaryContext $ \\context -> case withValidatedNestedLifecycleContext context $ \\_ contextStore current frame validated ->"
                        , producer
                        )
                    ,
                        ( "remote and local child frames meet only by closed textual and topology checks"
                        , "requireText \"signed child frame\" (handoffChildFrame signed) child require \"immediate topology edge\" $ [topologyEdge | topologyEdge@(_, edgeChild) <- topologyParentEdges (topology plan), edgeChild == child] == [(handoffParentFrame signed, child)]"
                        , producer
                        )
                    ,
                        ( "canonical adapter equality precedes protected recovery admission"
                        , "withVerifiedReverseAdapterKernel plan current verb adapter (\\teardown -> do opened <- reopenAuthenticatedRecoveryChildCursorKernel acquisitionJournalAdmissionKernel store signed plan digestBinding frame verb"
                        , producer
                        )
                    ,
                        ( "the immutable Prepare seed and exact Teardown cursor are rechecked"
                        , "requireWord \"acquisition record version\" (1 :: Word64) (acquisitionJournalRecordVersion journal) withAcquisitionJournalPhase journal $ \\phase -> requireText \"acquisition seed\" \"prepare\" (lifecyclePhaseName phase)"
                        , producer
                        )
                    ,
                        ( "the sole child reservation is exact Teardown authority"
                        , "reserveCurrentLifecycleCommandKernel journal cursor $ childCommandReservationKernel (handoffInstalledProject signed) (handoffStoreIdentity signed) (handoffBrokerGeneration signed) verb (handoffPlanRevision signed) Teardown (projectFrameId frame)"
                        , producer
                        )
                    ,
                        ( "the reserved authority is checked before the origin is sealed"
                        , "require \"command store\" (commandAuthorityMatchesStore authority store) require \"cursor command origin\" (lifecycleCursorMatchesCommandAuthority authority cursor)"
                        , producer
                        )
                    ,
                        ( "the origin receives the entire exact local package only after reservation"
                        , "withChildRecoveryOriginKernel descent plan digestBinding context teardown journal cursor authority use"
                        , producer
                        )
                    ,
                        ( "the producer can run only under the fixed received-package eliminator"
                        , "in withReceivedRecoveryDescent descent admitReceived"
                        , producer
                        )
                    ]
                assertFragmentsInOrder
                    "local plan, context, adapter, protected cursor, reservation, and origin remain ordered"
                    [ "validateEnvelope signed verb adapter projection grant"
                    , "withChildProjectPlanKernel"
                    , "validatePlanHere"
                    , "withValidatedLifecycleContext"
                    , "withValidatedNestedLifecycleContext"
                    , "validateNestedHere"
                    , "withVerifiedReverseAdapterKernel"
                    , "reopenAuthenticatedRecoveryChildCursorKernel"
                    , "validateRuntimeHere"
                    , "reserveCurrentLifecycleCommandKernel"
                    , "validateReservedHere"
                    , "withChildRecoveryOriginKernel"
                    ]
                    producer
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name producerSource @?= 0)
                    [ "projectPlanDrafts"
                    , "FinalizedProjectSpec"
                    , "withProjectPlan"
                    , "LifecycleEntry"
                    , "RootInvocationAuthority"
                    , "unsafeCoerce"
                    , "coerce"
                    , "runChainFromFrame"
                    , "withTeardownLifecycleCursor"
                    , "renderReverseAdapter"
                    , "compareAndSwapProtectedRecord"
                    , "writeProtectedRecord"
                    , "openTeardownForest"
                    , "settleDescentWork"
                    , "failDescentWork"
                    , "driveTeardownForest"
                    , "verifySubtreeSettled"
                    , "SubtreeSettled"
                    , "DestroySettled"
                    , "withChildRecoveryTerminalOriginKernel"
                    , "result"
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name authorityInternalSource @?= 0)
                    [ "RootInvocationAuthority"
                    , "LifecycleEntry"
                    , "CommandReservation"
                    , "withProtectedEntry"
                    , "compareAndSwapProtectedRecord"
                    , "writeProtectedRecord"
                    , "unsafeCoerce"
                    , "result"
                    , "settleDescentWork"
                    , "driveTeardownForest"
                    ]
                SourceGuard.countHaskellIdentifier "withReceivedRecoveryDescent" originSealer @?= 1
                SourceGuard.countHaskellIdentifier "withReceivedRecoveryDescent" terminalSource @?= 1
                SourceGuard.countHaskellIdentifier "withChildProjectPlanKernel" producerSource @?= 1
                SourceGuard.countHaskellIdentifier "withValidatedLifecycleContext" producerSource @?= 1
                SourceGuard.countHaskellIdentifier "withValidatedNestedLifecycleContext" producerSource @?= 1
                SourceGuard.countHaskellIdentifier "withVerifiedReverseAdapterKernel" producerSource @?= 1
                SourceGuard.countHaskellIdentifier
                    "reopenAuthenticatedRecoveryChildCursorKernel"
                    producerSource
                    @?= 1
                SourceGuard.countHaskellIdentifier "childCommandReservationKernel" producerSource @?= 1
                SourceGuard.countHaskellIdentifier "reserveCurrentLifecycleCommandKernel" producerSource @?= 1
                SourceGuard.countHaskellIdentifier "withChildRecoveryOriginKernel" producerSource @?= 1
                assertBool
                    "Child.Internal must not reverse the Construct dependency"
                    (not (SourceGuard.importsModule "HostBootstrap.ProjectPlan.Construct" childSource))
                assertBool
                    "Construct retains its one-way dependency on Child.Internal"
                    (SourceGuard.importsModule "HostBootstrap.ProjectPlan.Child.Internal" constructSource)
                assertBool
                    "Child.Internal imports the recovery-origin authority module"
                    (SourceGuard.importsModule "HostBootstrap.Authority.ProjectPlan.Internal" childSource)
                assertBool
                    "LifecycleEntry imports the abstract recovery-origin authority module"
                    (SourceGuard.importsModule "HostBootstrap.Authority.ProjectPlan.Internal" entrySource)
                SourceGuard.countHaskellIdentifier "withChildRecoveryOriginKernel" entrySource @?= 0
                sources <- readProductionSources sourceRoot
                let sites name =
                        [ (moduleName, count)
                        | (moduleName, _path, sourceBody) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name sourceBody
                        , count > 0
                        ]
                    importers moduleName =
                        [ sourceModule
                        | (sourceModule, _path, sourceBody) <- sources
                        , SourceGuard.importsModule moduleName sourceBody
                        ]
                sites "withReceivedRecoveryChildOriginKernel"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 2)
                        , ("HostBootstrap.ProjectPlan.Child.Internal", 4)
                        ]
                sites "ChildRecoveryOrigin"
                    @?= [ ("HostBootstrap.Authority.ProjectPlan.Internal", 13)
                        , ("HostBootstrap.Command.LifecycleEntry", 2)
                        , ("HostBootstrap.ProjectPlan.Child.Internal", 2)
                        ]
                sites "withChildRecoveryOriginKernel"
                    @?= [ ("HostBootstrap.Authority.ProjectPlan.Internal", 3)
                        , ("HostBootstrap.ProjectPlan.Child.Internal", 2)
                        ]
                sites "childRecoveryOriginFrameNameKernel"
                    @?= [ ("HostBootstrap.Authority.ProjectPlan.Internal", 3)
                        , ("HostBootstrap.Command.LifecycleEntry", 2)
                        ]
                sites "childRecoveryOriginVerbNameKernel"
                    @?= [ ("HostBootstrap.Authority.ProjectPlan.Internal", 3)
                        , ("HostBootstrap.Command.LifecycleEntry", 2)
                        ]
                sites "withChildRecoveryTerminalOriginKernel"
                    @?= [ ("HostBootstrap.Authority.ProjectPlan.Internal", 3)
                        , ("HostBootstrap.Command.LifecycleEntry", 2)
                        ]
                sites "reopenAuthenticatedRecoveryChildCursorKernel"
                    @?= [ ("HostBootstrap.Lifecycle.Mode", 4)
                        , ("HostBootstrap.ProjectPlan.Child.Internal", 2)
                        ]
                sites "withVerifiedReverseAdapterKernel"
                    @?= [ ("HostBootstrap.ProjectPlan.Child.Internal", 2)
                        , ("HostBootstrap.Teardown.Internal", 3)
                        ]
                sites "withReceivedRecoveryDescent"
                    @?= [ ("HostBootstrap.Authority.ProjectPlan.Internal", 3)
                        , ("HostBootstrap.Command.Child", 3)
                        , ("HostBootstrap.Handoff.Receiver.Internal", 3)
                        , ("HostBootstrap.Handoff.Relay", 3)
                        , ("HostBootstrap.ProjectPlan.Child.Internal", 2)
                        ]
                importers "HostBootstrap.Authority.ProjectPlan.Internal"
                    @?= [ "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.ProjectPlan.Child.Internal"
                        ]
                importers "HostBootstrap.ProjectPlan.Child.Internal"
                    @?= [ "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.ProjectPlan.Construct"
                        ]
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "ChildRecoveryOrigin"
                    , "withReceivedRecoveryChildOriginKernel"
                    , "withChildRecoveryOriginKernel"
                    , "childRecoveryOriginFrameNameKernel"
                    , "childRecoveryOriginVerbNameKernel"
                    , "withChildRecoveryTerminalOriginKernel"
                    ]
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                librarySource <-
                    maybe
                        (assertFailure "the main library stanza is missing")
                        pure
                        (mainLibraryStanza cabalSource)
                let exposedModules = fieldModules "exposed-modules:" librarySource
                    otherModules = fieldModules "other-modules:" librarySource
                length
                    (filter (== "HostBootstrap.Authority.ProjectPlan.Internal") otherModules)
                    @?= 1
                length
                    (filter (== "HostBootstrap.ProjectPlan.Child.Internal") otherModules)
                    @?= 1
                assertBool
                    "the recovery-origin authority module is not exposed"
                    ("HostBootstrap.Authority.ProjectPlan.Internal" `notElem` exposedModules)
                assertBool
                    "the recovery-child producer module is not exposed"
                    ("HostBootstrap.ProjectPlan.Child.Internal" `notElem` exposedModules)
                mapM_
                    (\name -> assertAbsent "a recovery-child runtime testing seam" name cabalSource)
                    [ "HostBootstrap.Authority.ProjectPlan.Internal.Testing"
                    , "HostBootstrap.ProjectPlan.Child.Internal.Testing"
                    , "HostBootstrap.ProjectPlan.Child.Recovery.Testing"
                    , "HostBootstrap.Command.LifecycleEntry.Recovery.Testing"
                    ]
        , testCase "recovery child lifecycle entry is sealed, fixed-unit, and caller-free" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                entrySource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Command" </> "LifecycleEntry.hs")
                constructSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Construct.hs")
                childSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Child" </> "Internal.hs")
                authorityInternalSource <-
                    readFile
                        ( sourceRoot
                            </> "HostBootstrap"
                            </> "Authority"
                            </> "ProjectPlan"
                            </> "Internal.hs"
                        )
                entrySchemaSource <-
                    requiredSourceSection
                        "recovery-child lifecycle-entry schema"
                        "data LifecycleEntry scope planId frame brokerGeneration verb where"
                        "type role LifecycleEntry"
                        entrySource
                entryViewsSource <-
                    requiredSourceSection
                        "recovery-child lifecycle-entry descriptive views"
                        "lifecycleEntryFrameName ::"
                        "{- | Admit or exactly resume one root"
                        entrySource
                preparedSource <-
                    requiredSourceSection
                        "recovery-child prepared-descent refusal"
                        "withPreparedRootReverseDescentKernel ::"
                        "{- | Seal one authenticated recovery child"
                        entrySource
                producerSource <-
                    requiredSourceSection
                        "fixed-unit recovery-child lifecycle-entry producer"
                        "withReceivedRecoveryChildLifecycleEntry ::"
                        "{- | Emit only the canonical byte identity"
                        entrySource
                terminalSource <-
                    requiredSourceSection
                        "fixed-unit recovery-child terminal fold"
                        "withChildRecoveryTerminalOrigin ::"
                        "{- | Admit exactly one authenticated child Up/Execute entry"
                        entrySource
                rootRunnerSource <-
                    requiredSourceSection
                        "root Up recovery-child refusal"
                        "runRootProjectUpLifecycleEntry ::"
                        "{- | Interpret one child-origin Up entry"
                        entrySource
                let childRunnerSource =
                        unlines
                            ( dropWhile
                                (not . isPrefixOf "runChildProjectUpLifecycleEntry ::")
                                (lines entrySource)
                            )
                assertBool
                    "the child Up recovery-child refusal marker is missing"
                    (not (null childRunnerSource))
                entryExports <-
                    requiredModuleExports "HostBootstrap.Command.LifecycleEntry" entrySource
                let exported = filter (/= ",") entryExports
                    recoveryEntryExports =
                        [ "withReceivedRecoveryChildLifecycleEntry"
                        , "withChildRecoveryTerminalOrigin"
                        ]
                    namedTypes =
                        [ stripped
                        | sourceLine <- lines entrySource
                        , let stripped = dropWhile isSpace sourceLine
                        , "data " `isPrefixOf` stripped
                            || "newtype " `isPrefixOf` stripped
                            || ("type " `isPrefixOf` stripped && not ("type role " `isPrefixOf` stripped))
                        ]
                    constructors =
                        [ name
                        | sourceLine <- lines entrySchemaSource
                        , [name, "::"] <- [words sourceLine]
                        ]
                    entry = normalizeWhitespace entrySource
                    schema = normalizeWhitespace entrySchemaSource
                    views = normalizeWhitespace entryViewsSource
                    prepared = normalizeWhitespace preparedSource
                    producer = normalizeWhitespace producerSource
                    terminal = normalizeWhitespace terminalSource
                    rootRunner = normalizeWhitespace rootRunnerSource
                    childRunner = normalizeWhitespace childRunnerSource
                filter (`elem` recoveryEntryExports) exported @?= recoveryEntryExports
                assertBool
                    "the recovery-child constructor is not exported from the hidden Entry module"
                    ("ChildRecoveryLifecycleEntry" `notElem` exported)
                namedTypes
                    @?= ["data LifecycleEntry scope planId frame brokerGeneration verb where"]
                constructors
                    @?= [ "RootUpLifecycleEntry"
                        , "ChildUpLifecycleEntry"
                        , "ChildRecoveryLifecycleEntry"
                        , "RootDownLifecycleEntry"
                        , "RootDestroyLifecycleEntry"
                        ]
                mapM_
                    (\(label, fragment, body) -> assertContains label fragment body)
                    [
                        ( "the existing entry family retains exactly five nominal roles"
                        , "type role LifecycleEntry nominal nominal nominal nominal nominal"
                        , entry
                        )
                    ,
                        ( "the recovery-child constructor retains only the sealed nine-role origin"
                        , "ChildRecoveryLifecycleEntry :: ChildRecoveryOrigin scope specDigest planDigest brokerGeneration parentFrame planId configId frame verb -> LifecycleEntry scope planId frame brokerGeneration verb"
                        , schema
                        )
                    ,
                        ( "the frame accessor delegates to the sealed origin view"
                        , "lifecycleEntryFrameName (ChildRecoveryLifecycleEntry origin) = childRecoveryOriginFrameNameKernel origin"
                        , views
                        )
                    ,
                        ( "the verb accessor delegates to the sealed origin view"
                        , "lifecycleEntryVerbName (ChildRecoveryLifecycleEntry origin) = childRecoveryOriginVerbNameKernel origin"
                        , views
                        )
                    ,
                        ( "the wrapper accepts the received package and independently typed project inputs"
                        , "ReceivedRecoveryDescent (Production projectId) brokerGeneration planDigest parentFrame signedChildFrame recoveryWireDigest recoveryWireId verb -> ProtectedStore -> CanonicalProjectRoot (Production projectId) rootId -> FinalizedProjectSpec (Production projectId) specDigest cfg -> ValidatedConfig (Production projectId) specDigest configId (cfg (Production projectId)) -> Context.BinaryContext"
                        , producer
                        )
                    ,
                        ( "the wrapper fixes both its callback and outer result to unit"
                        , "LifecycleEntry (Production projectId) localPlanId localFrame brokerGeneration verb -> IO (Either Text ()) ) -> IO (Either Text ())"
                        , producer
                        )
                    ,
                        ( "the wrapper is unary, opaque, and strict in the received descent"
                        , "{-# OPAQUE withReceivedRecoveryChildLifecycleEntry #-} withReceivedRecoveryChildLifecycleEntry descent = case descent `seq` () of"
                        , producer
                        )
                    ,
                        ( "Entry alone derives the exact local typed drafts"
                        , "case projectPlanDrafts finalizedSpec root config of"
                        , producer
                        )
                    ,
                        ( "the lower producer alone seals the retained recovery origin"
                        , "withReceivedRecoveryChildOriginKernel descent store root config drafts binaryContext (\\origin -> use (ChildRecoveryLifecycleEntry origin))"
                        , producer
                        )
                    ,
                        ( "the prepared root kernel refuses a recovery-child origin"
                        , "ChildRecoveryLifecycleEntry{} -> refused"
                        , prepared
                        )
                    ,
                        ( "prepared refusal returns the original work unchanged"
                        , "TeardownReverseDescentRefused \"only a root Down or Destroy entry can prepare descent\" , descent"
                        , prepared
                        )
                    ,
                        ( "the terminal fold has a byte-only fixed-unit callback"
                        , "(ByteString.ByteString -> IO (Either Text ())) -> IO (Either Text ())"
                        , terminal
                        )
                    ,
                        ( "the terminal fold delegates the sealed origin without projecting it"
                        , "ChildRecoveryLifecycleEntry origin -> withChildRecoveryTerminalOriginKernel origin use"
                        , terminal
                        )
                    ,
                        ( "the root Up runner refuses a recovery child"
                        , "(ChildRecoveryLifecycleEntry _) = pure (Left \"lifecycle entry: the root interpreter refuses a recovery child origin\")"
                        , rootRunner
                        )
                    ,
                        ( "the child Up runner refuses a recovery child"
                        , "runChildProjectUpLifecycleEntry _cfg _self (ChildRecoveryLifecycleEntry{}) _complete = pure (Left \"lifecycle entry: the child Up interpreter refuses a recovery origin\")"
                        , childRunner
                        )
                    ]
                assertFragmentsInOrder
                    "received descent strictness precedes drafts, lower admission, and entry sealing"
                    [ "withReceivedRecoveryChildLifecycleEntry descent ="
                    , "case descent `seq` () of"
                    , "projectPlanDrafts finalizedSpec root config"
                    , "withReceivedRecoveryChildOriginKernel"
                    , "ChildRecoveryLifecycleEntry origin"
                    ]
                    producer
                assertFragmentsInOrder
                    "the terminal fold accepts only recovery children and refuses every other entry"
                    [ "ChildRecoveryLifecycleEntry origin -> withChildRecoveryTerminalOriginKernel origin use"
                    , "RootUpLifecycleEntry{} -> refused"
                    , "ChildUpLifecycleEntry{} -> refused"
                    , "RootDownLifecycleEntry{} -> refused"
                    , "RootDestroyLifecycleEntry{} -> refused"
                    ]
                    terminal
                SourceGuard.countHaskellIdentifier "projectPlanDrafts" producerSource @?= 1
                SourceGuard.countHaskellIdentifier
                    "withReceivedRecoveryChildOriginKernel"
                    producerSource
                    @?= 1
                SourceGuard.countHaskellIdentifier "ChildRecoveryLifecycleEntry" producerSource @?= 1
                SourceGuard.countHaskellIdentifier
                    "withChildRecoveryTerminalOriginKernel"
                    terminalSource
                    @?= 1
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name producerSource @?= 0)
                    [ "HandoffBinding"
                    , "HandoffBindingInput"
                    , "HandoffToken"
                    , "RootInvocationAuthority"
                    , "ProjectVerb"
                    , "AcquisitionJournal"
                    , "LifecycleCursor"
                    , "CommandAuthority"
                    , "withReceivedRecoveryDescent"
                    , "withChildRecoveryOriginKernel"
                    , "unsafeCoerce"
                    , "coerce"
                    , "runChainFromFrame"
                    , "withProtectedEntry"
                    , "compareAndSwapProtectedRecord"
                    , "writeProtectedRecord"
                    , "openTeardownForest"
                    , "settleDescentWork"
                    , "failDescentWork"
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name terminalSource @?= 0)
                    [ "ReceivedRecoveryDescent"
                    , "withReceivedRecoveryDescent"
                    , "ProjectPlan"
                    , "ValidatedLifecycleContext"
                    , "AcquisitionJournal"
                    , "LifecycleCursor"
                    , "CommandAuthority"
                    , "withChildRecoveryOriginKernel"
                    , "projectPlanDrafts"
                    , "runChainFromFrame"
                    , "withProtectedEntry"
                    , "compareAndSwapProtectedRecord"
                    , "writeProtectedRecord"
                    ]
                assertBool
                    "Entry imports the abstract child-origin API"
                    (SourceGuard.importsModule "HostBootstrap.Authority.ProjectPlan.Internal" entrySource)
                assertBool
                    "Entry imports the typed-draft owner"
                    (SourceGuard.importsModule "HostBootstrap.ProjectPlan.Construct" entrySource)
                assertBool
                    "Entry imports the lower child-origin producer"
                    (SourceGuard.importsModule "HostBootstrap.ProjectPlan.Child.Internal" entrySource)
                assertBool
                    "Entry does not import the received-package eliminator"
                    (not (SourceGuard.importsModule "HostBootstrap.Handoff.Receiver.Internal" entrySource))
                assertBool
                    "Construct retains its one-way dependency on Child.Internal"
                    (SourceGuard.importsModule "HostBootstrap.ProjectPlan.Child.Internal" constructSource)
                assertBool
                    "Child.Internal retains its one-way dependency on Authority.Internal"
                    (SourceGuard.importsModule "HostBootstrap.Authority.ProjectPlan.Internal" childSource)
                mapM_
                    (\dependency -> assertBool "the lower origin authority does not reverse the Entry DAG" (not dependency))
                    [ SourceGuard.importsModule "HostBootstrap.Command.LifecycleEntry" authorityInternalSource
                    , SourceGuard.importsModule "HostBootstrap.ProjectPlan.Construct" authorityInternalSource
                    , SourceGuard.importsModule "HostBootstrap.ProjectPlan.Child.Internal" authorityInternalSource
                    , SourceGuard.importsModule "HostBootstrap.Command.LifecycleEntry" childSource
                    , SourceGuard.importsModule "HostBootstrap.ProjectPlan.Construct" childSource
                    ]
                SourceGuard.countHaskellIdentifier "withReceivedRecoveryDescent" entrySource @?= 0
                SourceGuard.countHaskellIdentifier "withChildRecoveryOriginKernel" entrySource @?= 0
                sources <- readProductionSources sourceRoot
                let sites name =
                        [ (moduleName, count)
                        | (moduleName, _path, sourceBody) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name sourceBody
                        , count > 0
                        ]
                    exactDraftCallers =
                        [ moduleName
                        | (moduleName, _path, sourceBody) <- sources
                        , "case projectPlanDrafts finalizedSpec root config of"
                            `isInfixOf` normalizeWhitespace sourceBody
                        ]
                sites "ChildRecoveryLifecycleEntry"
                    @?= [("HostBootstrap.Command.LifecycleEntry", 15)]
                sites "withReceivedRecoveryChildLifecycleEntry"
                    @?= [("HostBootstrap.Command.LifecycleEntry", 4)]
                sites "withChildRecoveryTerminalOrigin"
                    @?= [ ("HostBootstrap.Command.LifecycleEntry", 3)
                        , ("HostBootstrap.Handoff.Lifecycle", 2)
                        ]
                exactDraftCallers @?= ["HostBootstrap.Command.LifecycleEntry"]
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                mapM_
                    (\name -> modulesExporting name publicExports @?= [])
                    [ "ChildRecoveryLifecycleEntry"
                    , "withReceivedRecoveryChildLifecycleEntry"
                    , "withChildRecoveryTerminalOrigin"
                    , "lifecycleEntryRecoveryOrigin"
                    , "lifecycleEntryRecoveryDescent"
                    ]
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                librarySource <-
                    maybe
                        (assertFailure "the main library stanza is missing")
                        pure
                        (mainLibraryStanza cabalSource)
                let exposedModules = fieldModules "exposed-modules:" librarySource
                    otherModules = fieldModules "other-modules:" librarySource
                length (filter (== "HostBootstrap.Command.LifecycleEntry") otherModules) @?= 1
                assertBool
                    "LifecycleEntry remains hidden"
                    ("HostBootstrap.Command.LifecycleEntry" `notElem` exposedModules)
                mapM_
                    (\name -> assertAbsent "a recovery-child Entry runtime testing seam" name cabalSource)
                    [ "HostBootstrap.Command.LifecycleEntry.Recovery.Testing"
                    , "HostBootstrap.Command.LifecycleEntry.ChildRecovery.Testing"
                    , "HostBootstrap.Command.RecoveryChild.Testing"
                    ]
        , testCase "authenticated child entry is closed before mutation and terminalizes before completion" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                authoritySource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Authority" </> "ProjectPlan.hs")
                childSource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Child" </> "Internal.hs")
                entrySource <-
                    readFile (sourceRoot </> "HostBootstrap" </> "Command" </> "LifecycleEntry.hs")
                producerSource <-
                    requiredSourceSection
                        "authenticated child entry producer"
                        "withChildProjectUpLifecycleEntry ::"
                        "{- | Interpret exactly one admitted root"
                        entrySource
                let child = normalizeWhitespace childSource
                    entry = normalizeWhitespace entrySource
                    producer = normalizeWhitespace producerSource
                mapM_
                    (\(label, fragment, source) -> assertContains label fragment source)
                    [
                        ( "the pre-mutation closed verb and phase branch"
                        , "case verb of ProjectUp -> case verifiedConfigHandoffPhase handoff of Execute -> do joined <- withAuthenticatedChildCursor"
                        , producer
                        )
                    ,
                        ( "the Prepare refusal before the bridge"
                        , "Prepare -> pure (Left \"lifecycle entry: child Up requires Execute, not Prepare\")"
                        , producer
                        )
                    ,
                        ( "the Teardown refusal before the bridge"
                        , "Teardown -> pure (Left \"lifecycle entry: child Up requires Execute, not Teardown\")"
                        , producer
                        )
                    ,
                        ( "the Down refusal before the bridge"
                        , "ProjectDown -> pure (Left \"lifecycle entry: config-origin child entry refuses Down\")"
                        , producer
                        )
                    ,
                        ( "the Destroy refusal before the bridge"
                        , "ProjectDestroy -> pure (Left \"lifecycle entry: config-origin child entry refuses Destroy\")"
                        , producer
                        )
                    ,
                        ( "the whole authenticated package is forced"
                        , "authenticated@( AuthenticatedChildCursor handoff authority plan digestBinding lifecycleContext journal cursor )"
                        , child
                        )
                    ,
                        ( "the authorized package's nominal indices"
                        , "type role AuthorizedChildCursor nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal"
                        , child
                        )
                    ,
                        ( "the entry stores one authorized child package"
                        , "ChildUpLifecycleEntry :: AuthorizedChildCursor"
                        , entry
                        )
                    ,
                        ( "the fixed runner transitions before completion"
                        , "Right (Right ()) -> do transitioned <- withTeardownLifecycleCursor cursor $ \\teardownCursor -> complete (AuthorizedTeardownChildCursor authorized teardownCursor)"
                        , child
                        )
                    ,
                        ( "the terminal identity binds the Teardown version"
                        , "word (lifecycleCursorRecordVersion teardownCursor)"
                        , child
                        )
                    ]
                SourceGuard.countHaskellIdentifier "withAuthenticatedChildCursor" producerSource @?= 1
                SourceGuard.countHaskellIdentifier "authorizeChildProject" authoritySource @?= 0
                SourceGuard.countHaskellIdentifier "withForwardTerminalOrigin" entrySource @?= 0
                SourceGuard.countHaskellIdentifier "unsafeCoerce" childSource @?= 0
                Text.count
                    "AuthorizedTeardownChildCursor authorized teardownCursor"
                    (Text.pack childSource)
                    @?= 1
        ]

withPackageSourceRoot :: (FilePath -> FilePath -> IO result) -> IO result
withPackageSourceRoot use = do
    cwd <- getCurrentDirectory
    repoRoot <-
        findRepoRoot cwd
            >>= maybe
                (assertFailure ("could not locate repo root from " <> cwd))
                pure
    let packageRoot = repoRoot </> "core" </> "hostbootstrap-core"
    use packageRoot (packageRoot </> "src")

readProductionSources :: FilePath -> IO [(String, FilePath, String)]
readProductionSources sourceRoot = do
    paths <- listHaskellSources sourceRoot
    traverse
        ( \path -> do
            source <- readFile path
            pure (moduleNameFromPath sourceRoot path, path, source)
        )
        paths

readPublicModuleExports :: FilePath -> FilePath -> IO [(String, [String])]
readPublicModuleExports packageRoot sourceRoot = do
    cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
    librarySource <-
        maybe
            (assertFailure "hostbootstrap-core.cabal has no main library stanza" >> pure "")
            pure
            (mainLibraryStanza cabalSource)
    sources <- readProductionSources sourceRoot
    let exposed = sort (fieldModules "exposed-modules:" librarySource)
        sourceByModule =
            [ (moduleName, source)
            | (moduleName, _path, source) <- sources
            ]
        missing =
            filter
                (\moduleName -> moduleName `notElem` map fst sourceByModule)
                exposed
    assertBool
        ("main-library exposed module source(s) missing: " <> show missing)
        (null missing)
    traverse
        ( \moduleName -> do
            source <-
                maybe
                    (assertFailure ("source missing for exposed module " <> moduleName) >> pure "")
                    pure
                    (lookup moduleName sourceByModule)
            exports <- requiredModuleExports moduleName source
            pure (moduleName, exports)
        )
        exposed

requiredModuleExports :: String -> String -> IO [String]
requiredModuleExports moduleName source =
    case SourceGuard.moduleExportTokens moduleName source of
        Nothing ->
            assertFailure
                (moduleName <> " has no lexically visible explicit export list")
                >> pure []
        Just exports -> pure exports

modulesExporting :: String -> [(String, [String])] -> [String]
modulesExporting exported =
    sort
        . map fst
        . filter (elem exported . snd)

containsTokenSequence :: (Eq token) => [token] -> [token] -> Bool
containsTokenSequence [] _observed = True
containsTokenSequence _expected [] = False
containsTokenSequence expected observed@(_ : rest) =
    tokenPrefix expected observed || containsTokenSequence expected rest
  where
    tokenPrefix [] _ = True
    tokenPrefix _ [] = False
    tokenPrefix (wanted : wantedRest) (actual : actualRest) =
        wanted == actual && tokenPrefix wantedRest actualRest

listHaskellSources :: FilePath -> IO [FilePath]
listHaskellSources directory = do
    entries <- sort <$> listDirectory directory
    fmap concat $
        traverse
            ( \entry -> do
                let path = directory </> entry
                isDirectory <- doesDirectoryExist path
                if isDirectory
                    then listHaskellSources path
                    else pure [path | takeExtension path == ".hs"]
            )
            entries

moduleNameFromPath :: FilePath -> FilePath -> String
moduleNameFromPath = SourceGuard.repoRelativeModuleName

mainLibraryStanza :: String -> Maybe String
mainLibraryStanza source =
    case dropWhile ((/= "library") . trim) (lines source) of
        [] -> Nothing
        _library : rest ->
            Just
                ( unlines
                    ( takeWhile
                        isLibraryContinuation
                        rest
                    )
                )
  where
    isLibraryContinuation [] = True
    isLibraryContinuation line@(firstCharacter : _) =
        null (trim line) || isSpace firstCharacter

fieldModules :: String -> String -> [String]
fieldModules field = go . lines
  where
    go [] = []
    go (line : rest)
        | Just inline <- stripPrefix field (trim line) =
            let fieldIndent = indentation line
                (continuation, remaining) =
                    span
                        (\next -> null (trim next) || indentation next > fieldIndent)
                        rest
             in moduleTokens (inline : continuation) <> go remaining
        | otherwise = go rest

    moduleTokens =
        filter ("HostBootstrap." `isPrefixOf`)
            . map (filter (/= ','))
            . words
            . unlines

indentation :: String -> Int
indentation = length . takeWhile isSpace

normalizeWhitespace :: String -> String
normalizeWhitespace = unwords . words

significantHaskellLineCount :: String -> Int
significantHaskellLineCount = length . filter (not . all isSpace) . stripComments 0 . lines
  where
    stripComments :: Int -> [String] -> [String]
    stripComments _ [] = []
    stripComments depth (sourceLine : remaining) =
        let (nextDepth, code) = stripLine depth sourceLine
         in code : stripComments nextDepth remaining

    stripLine :: Int -> String -> (Int, String)
    stripLine = go

    go :: Int -> String -> (Int, String)
    go depth [] = (depth, [])
    go 0 ('-' : '-' : _) = (0, [])
    go 0 ('{' : '-' : '#' : remaining) =
        let (nextDepth, code) = go 0 remaining
         in (nextDepth, "{-#" <> code)
    go depth ('{' : '-' : remaining) = go (depth + 1) remaining
    go depth ('-' : '}' : remaining)
        | depth > 0 = go (depth - 1) remaining
    go 0 (character : remaining) =
        let (nextDepth, code) = go 0 remaining
         in (nextDepth, character : code)
    go depth (_ : remaining) = go depth remaining

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

requiredSourceSection :: String -> String -> String -> String -> IO String
requiredSourceSection label opening closing source =
    case dropThrough opening source >>= takeBefore closing of
        Nothing ->
            assertFailure
                ( label
                    <> " is not bounded by the expected source markers "
                    <> show opening
                    <> " and "
                    <> show closing
                )
                >> pure ""
        Just section -> pure section

dropThrough :: String -> String -> Maybe String
dropThrough needle = go
  where
    go [] = Nothing
    go remaining@(_character : rest)
        | needle `isPrefixOf` remaining = Just (drop (length needle) remaining)
        | otherwise = go rest

takeBefore :: String -> String -> Maybe String
takeBefore needle = go []
  where
    go _ [] = Nothing
    go reversed remaining@(character : rest)
        | needle `isPrefixOf` remaining = Just (reverse reversed)
        | otherwise = go (character : reversed) rest

assertRequiredMembers :: String -> [String] -> [String] -> IO ()
assertRequiredMembers label required observed =
    let missing = filter (`notElem` observed) required
     in assertBool
            (label <> " missing " <> show missing <> "; observed " <> show observed)
            (null missing)

assertContains :: String -> String -> String -> IO ()
assertContains label expected source =
    assertBool
        (label <> " is missing source shape: " <> show expected)
        (expected `isInfixOf` source)

assertAbsent :: String -> String -> String -> IO ()
assertAbsent label forbidden source =
    assertBool
        (label <> ": " <> show forbidden)
        (not (forbidden `isInfixOf` source))

assertFragmentsInOrder :: String -> [String] -> String -> IO ()
assertFragmentsInOrder label fragments source = go source fragments
  where
    go _ [] = pure ()
    go remainingSource (fragment : remaining) =
        case dropThrough fragment remainingSource of
            Nothing ->
                assertFailure
                    ( label
                        <> " is missing or misorders source shape: "
                        <> show fragment
                    )
            Just after -> go after remaining

{- | The complete public package required for one recovered-plan reconstruction.

The indices are deliberately retained in one value so the success test can pin
the reconstructed 'ProjectPlan' to the exact @planId@ generated by existing
snapshot admission.
-}
data RecoveredProjectPlanInputs projectId specDigest planDigest planId brokerGeneration rootId configId
    = RecoveredProjectPlanInputs
        ( RecoveredProductionLifecycleProfile
            projectId
            specDigest
            planDigest
            planId
            brokerGeneration
        )
        (CanonicalProjectRoot (Production projectId) rootId)
        (VerifiedPlanSnapshot (Production projectId) specDigest planDigest)
        (BoundPlanSnapshot (Production projectId) specDigest planDigest planId)
        (PlanDigestBinding (Production projectId) specDigest planDigest planId)
        ( ValidatedConfig
            (Production projectId)
            specDigest
            configId
            (Fixture.ProjectConfig (Production projectId))
        )
        ( NonEmpty
            ( PlanDraft
                (Production projectId)
                specDigest
                (Fixture.ProjectConfig (Production projectId))
            )
        )

recoverProjectPlan ::
    RecoveredProjectPlanInputs
        projectId
        specDigest
        planDigest
        planId
        brokerGeneration
        rootId
        configId ->
    ( ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      result
    ) ->
    Either PlanError result
recoverProjectPlan
    (RecoveredProjectPlanInputs profile root verified bound binding config drafts) =
        withRecoveredProductionProjectPlan
            profile
            root
            verified
            bound
            binding
            config
            drafts

recoveredSnapshot ::
    ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
    StablePlanSnapshot
recoveredSnapshot = renderSnapshot

assertRecoveryMismatch :: Text.Text -> Either PlanError () -> IO ()
assertRecoveryMismatch expectedSubject outcome =
    case outcome of
        Left (PlanRecoveryEvidenceMismatch observedSubject _expected _observed)
            | observedSubject == expectedSubject -> pure ()
        other -> assertFailure ("expected recovered-plan refusal for " <> show expectedSubject <> ", observed " <> show other)

readAllProtectedRecords :: ProtectedStore -> IO [Maybe (RecordKey, ProtectedRecord)]
readAllProtectedRecords store = do
    observed <-
        withProtectedEntry store $ \session -> do
            listed <- listProtectedRecords session
            case listed of
                Left failure -> pure (Left failure)
                Right keys -> do
                    records <-
                        traverse
                            ( \key ->
                                fmap
                                    (fmap (fmap ((,) key)))
                                    (readProtectedRecord session key)
                            )
                            keys
                    pure (sequence records)
    either (fail . show) pure observed

withRecoveredProjectPlanFixture ::
    ( forall projectId brokerGeneration specDigest planDigest planId rootId configId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RecoveredProjectPlanInputs
        projectId
        specDigest
        planDigest
        planId
        brokerGeneration
        rootId
        configId ->
      IO result
    ) ->
    IO result
withRecoveredProjectPlanFixture use =
    withRecoveredProjectPlanCandidateFixture
        singletonPlan
        fixtureServiceRegistry
        ( \store project profile root verified bound binding candidateSpec candidateConfig ->
            case withRecoveredProductionProjectPlanInputs
                profile
                root
                candidateSpec
                candidateConfig
                ( \_recoveredSpec recoveredConfig recoveredDrafts ->
                    use
                        store
                        project
                        ( RecoveredProjectPlanInputs
                            profile
                            root
                            verified
                            bound
                            binding
                            recoveredConfig
                            recoveredDrafts
                        )
                ) of
                Left failure -> fail (show failure)
                Right action -> action
        )

withRecoveredProjectPlanCandidateFixture ::
    StepPlan ->
    ServiceRegistry Fixture.ProjectConfig ->
    ( forall
        projectId
        brokerGeneration
        recoveredSpecDigest
        planDigest
        planId
        rootId
        candidateSpecDigest
        candidateConfigId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RecoveredProductionLifecycleProfile
        projectId
        recoveredSpecDigest
        planDigest
        planId
        brokerGeneration ->
      CanonicalProjectRoot (Production projectId) rootId ->
      VerifiedPlanSnapshot
        (Production projectId)
        recoveredSpecDigest
        planDigest ->
      BoundPlanSnapshot
        (Production projectId)
        recoveredSpecDigest
        planDigest
        planId ->
      PlanDigestBinding
        (Production projectId)
        recoveredSpecDigest
        planDigest
        planId ->
      FinalizedProjectSpec
        (Production projectId)
        candidateSpecDigest
        Fixture.ProjectConfig ->
      ValidatedConfig
        (Production projectId)
        candidateSpecDigest
        candidateConfigId
        (Fixture.ProjectConfig (Production projectId)) ->
      IO result
    ) ->
    IO result
withRecoveredProjectPlanCandidateFixture = withRecoveredProjectPlanCandidateFixtureUsing fixtureServiceRegistry

{- | The candidate fixture with the recorded finalization's registry chosen, so
a recovery whose recorded and candidate registries agree can be exercised.
-}
withRecoveredProjectPlanCandidateFixtureUsing ::
    ServiceRegistry Fixture.ProjectConfig ->
    StepPlan ->
    ServiceRegistry Fixture.ProjectConfig ->
    ( forall
        projectId
        brokerGeneration
        recoveredSpecDigest
        planDigest
        planId
        rootId
        candidateSpecDigest
        candidateConfigId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RecoveredProductionLifecycleProfile
        projectId
        recoveredSpecDigest
        planDigest
        planId
        brokerGeneration ->
      CanonicalProjectRoot (Production projectId) rootId ->
      VerifiedPlanSnapshot
        (Production projectId)
        recoveredSpecDigest
        planDigest ->
      BoundPlanSnapshot
        (Production projectId)
        recoveredSpecDigest
        planDigest
        planId ->
      PlanDigestBinding
        (Production projectId)
        recoveredSpecDigest
        planDigest
        planId ->
      FinalizedProjectSpec
        (Production projectId)
        candidateSpecDigest
        Fixture.ProjectConfig ->
      ValidatedConfig
        (Production projectId)
        candidateSpecDigest
        candidateConfigId
        (Fixture.ProjectConfig (Production projectId)) ->
      IO result
    ) ->
    IO result
withRecoveredProjectPlanCandidateFixtureUsing recordedServices candidatePlan candidateServices use =
    withSnapshotPlanUsing recordedServices singletonPlan $ \store project rootAuthority unbound _persistedSpec root config _drafts plan -> do
        persisted <-
            withPersistedPlanSnapshot
                rootAuthority
                unbound
                plan
                (\_verified _bound _binding _boundLease _active -> pure ())
        either (fail . show) pure persisted
        admitted <-
            withBoundPlanSnapshot
                store
                project
                (\_closeKey -> assertFailure "the recovered-plan fixture entered the terminal callback")
                ( \exactRoot modeLease boundLease verified bound binding recovery ->
                    case withRecoveredProductionLifecycleProfile
                        exactRoot
                        modeLease
                        boundLease
                        verified
                        bound
                        binding
                        recovery
                        ( \profile ->
                            withProductionProjectCodec $ \candidateBaseCodec ->
                                withFinalizedProjectSpec
                                    ProductionScope
                                    candidateBaseCodec
                                    candidateServices
                                    (\_ _ -> Right candidatePlan)
                                    Fixture.refusingForwardChildPlan
                                    ( \candidateSpec -> do
                                        candidate <-
                                            withValidatedConfig
                                                (finalizedProjectCodec candidateSpec)
                                                (validatedConfigValue config)
                                                ( \_wire candidateConfig ->
                                                    use
                                                        store
                                                        project
                                                        profile
                                                        root
                                                        verified
                                                        bound
                                                        binding
                                                        candidateSpec
                                                        candidateConfig
                                                )
                                        either fail pure candidate
                                    )
                        ) of
                        Left failure -> fail (show failure)
                        Right action -> action
                )
        either (fail . show) pure admitted

pairedSnapshotEvidence ::
    VerifiedPlanSnapshot scope specDigest planDigest ->
    BoundPlanSnapshot scope specDigest planDigest planId ->
    PlanDigestBinding scope specDigest planDigest planId ->
    IO (Text.Text, Text.Text, ByteString.ByteString)
pairedSnapshotEvidence verified bound _binding =
    pure
        ( planSnapshotSpecDigest verified
        , planSnapshotPlanDigest verified
        , boundPlanSnapshotBytes bound
        )

exerciseFinalizedSpec ::
    FinalizedProjectSpec scope specDigest Fixture.ProjectConfig ->
    FilePath ->
    Fixture.ProjectConfig scope ->
    IO Text.Text
exerciseFinalizedSpec spec directory value = do
    rooted <-
        withCanonicalProjectRoot
            (directory </> "fixture.dhall")
            directory
            ( \root -> do
                admitted <-
                    withValidatedConfig
                        (finalizedProjectCodec spec)
                        value
                        ( \_wire validated -> do
                            let expectedDigest =
                                    projectCodecSpecDigest
                                        (finalizedProjectCodec spec)
                            validatedConfigSpecDigest validated @?= expectedDigest
                            plan <- expectRight (projectPlanStepPlan spec root validated)
                            drafts <- expectRight (projectPlanDrafts spec root validated)
                            NonEmpty.length drafts @?= length (stepPlanSteps plan)
                            finalizedServiceVariantNames
                                (finalizedProjectServices spec)
                                @?= ["probe"]
                            pure expectedDigest
                        )
                either fail pure admitted
            )
    either (fail . show) pure rooted

fixtureServiceRegistry :: ServiceRegistry Fixture.ProjectConfig
fixtureServiceRegistry =
    singletonServiceRegistry
        ( serviceDefinition
            (either (error . show) id (serviceId "probe"))
            (\_ -> Right (Just ()))
            NoEffects
            (const (pure ()))
        )

alternateFixtureServiceRegistry :: ServiceRegistry Fixture.ProjectConfig
alternateFixtureServiceRegistry =
    singletonServiceRegistry
        ( serviceDefinition
            (either (error . show) id (serviceId "alternate-probe"))
            (\_ -> Right (Just ()))
            NoEffects
            (const (pure ()))
        )

withFoundation ::
    ( forall projectId specDigest rootId configId.
      ProjectCodec (Production projectId) specDigest Fixture.ProjectConfig ->
      LifecycleProfile (Production projectId) ->
      CanonicalProjectRoot (Production projectId) rootId ->
      ValidatedConfig
        (Production projectId)
        specDigest
        configId
        (Fixture.ProjectConfig (Production projectId)) ->
      IO result
    ) ->
    IO result
withFoundation use =
    withSystemTempDirectory "hostbootstrap-project-plan" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
        Fixture.withFixtureInstalledProject $ \(project :: InstalledProjectIdentity projectId) -> do
            rooted <-
                withCanonicalProjectRoot
                    (directory </> "fixture.dhall")
                    "."
                    ( \(root :: CanonicalProjectRoot (Production projectId) rootId) ->
                        withProductionRoot store project ProjectUp $ \productionRoot -> do
                            opened <-
                                withProductionLifecycleProfile
                                    (rootScopeAuthority (productionRootAuthority productionRoot))
                                    (productionActiveMode (productionRootModeLease productionRoot))
                                    (productionRootUnboundLease productionRoot)
                                    ( \profile ->
                                        withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \codec -> do
                                            let value =
                                                    Fixture.defaultProjectConfig
                                                        (installedProjectName project)
                                                        (Text.pack (canonicalProjectRootPath root))
                                                        Context.HostOrchestrator
                                            validated <-
                                                withValidatedConfig codec value $ \_wire config ->
                                                    use codec profile root config
                                            either fail pure validated
                                    )
                            case opened of
                                Left failure -> pure (Left (ModeAuthorityFailure failure))
                                Right action -> Right <$> action
                    )
            admitted <- either (fail . show) pure rooted
            either (fail . show) pure admitted

withSnapshotPlan ::
    StepPlan ->
    ( forall projectId brokerGeneration specDigest rootId configId planId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      FinalizedProjectSpec
        (Production projectId)
        specDigest
        Fixture.ProjectConfig ->
      CanonicalProjectRoot (Production projectId) rootId ->
      ValidatedConfig
        (Production projectId)
        specDigest
        configId
        (Fixture.ProjectConfig (Production projectId)) ->
      NonEmpty
        ( PlanDraft
            (Production projectId)
            specDigest
            (Fixture.ProjectConfig (Production projectId))
        ) ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withSnapshotPlan = withSnapshotPlanUsing fixtureServiceRegistry

{- | The same fixture with the recorded finalization's own service registry
chosen, so a matched-registry recovery can be exercised alongside the default
drifted-candidate cases.
-}
withSnapshotPlanUsing ::
    ServiceRegistry Fixture.ProjectConfig ->
    StepPlan ->
    ( forall projectId brokerGeneration specDigest rootId configId planId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      FinalizedProjectSpec
        (Production projectId)
        specDigest
        Fixture.ProjectConfig ->
      CanonicalProjectRoot (Production projectId) rootId ->
      ValidatedConfig
        (Production projectId)
        specDigest
        configId
        (Fixture.ProjectConfig (Production projectId)) ->
      NonEmpty
        ( PlanDraft
            (Production projectId)
            specDigest
            (Fixture.ProjectConfig (Production projectId))
        ) ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withSnapshotPlanUsing recordedServices stepPlan use =
    withSystemTempDirectory "hostbootstrap-plan-digest-binding" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
        Fixture.withFixtureInstalledProject $ \(project :: InstalledProjectIdentity projectId) -> do
            rooted <-
                withCanonicalProjectRoot
                    (directory </> "fixture.dhall")
                    "."
                    ( \(root :: CanonicalProjectRoot (Production projectId) rootId) ->
                        withProductionRoot store project ProjectUp $ \productionRoot -> do
                            let unbound = productionRootUnboundLease productionRoot
                            opened <-
                                withProductionLifecycleProfile
                                    (rootScopeAuthority (productionRootAuthority productionRoot))
                                    (productionActiveMode (productionRootModeLease productionRoot))
                                    unbound
                                    ( \profile ->
                                        withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \baseCodec ->
                                            withFinalizedProjectSpec
                                                ProductionScope
                                                baseCodec
                                                recordedServices
                                                (\_ _ -> Right stepPlan)
                                                Fixture.refusingForwardChildPlan
                                                ( \spec -> do
                                                    let value =
                                                            Fixture.defaultProjectConfig
                                                                (installedProjectName project)
                                                                (Text.pack (canonicalProjectRootPath root))
                                                                Context.HostOrchestrator
                                                    validated <-
                                                        withValidatedConfig
                                                            (finalizedProjectCodec spec)
                                                            value
                                                            ( \_wire config -> do
                                                                drafts <- expectRight (projectPlanDrafts spec root config)
                                                                action <-
                                                                    expectRight
                                                                        ( withProjectPlan
                                                                            profile
                                                                            root
                                                                            config
                                                                            drafts
                                                                            ( use
                                                                                store
                                                                                project
                                                                                (productionRootAuthority productionRoot)
                                                                                unbound
                                                                                spec
                                                                                root
                                                                                config
                                                                                drafts
                                                                            )
                                                                        )
                                                                action
                                                            )
                                                    either fail pure validated
                                                )
                                    )
                            case opened of
                                Left failure -> pure (Left (ModeAuthorityFailure failure))
                                Right action -> Right <$> action
                    )
            admitted <- either (fail . show) pure rooted
            either (fail . show) pure admitted

writeRawPlanSnapshot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    Text.Text ->
    Text.Text ->
    Text.Text ->
    Text.Text ->
    ByteString.ByteString ->
    IO ()
writeRawPlanSnapshot store project runName specDigest planDigest configDigest canonicalBytes = do
    key <-
        either
            (fail . show)
            pure
            (mkRecordKey ("snapshot." <> installedProjectName project <> "." <> runName))
    written <-
        withProtectedEntry store $ \session ->
            fmap
                (fmap (const ()))
                ( compareAndSwapProtectedRecord
                    session
                    key
                    ExpectAbsent
                    payload
                )
    either (fail . show) pure written
  where
    payload =
        LazyByteString.toStrict
            ( Builder.toLazyByteString
                ( Builder.byteString "HOSTBOOTSTRAP-SNAPSHOT"
                    <> Builder.word64BE 1
                    <> Builder.word64BE 1
                    <> encodeSnapshotText specDigest
                    <> encodeSnapshotText planDigest
                    <> Builder.word8 1
                    <> encodeSnapshotText configDigest
                    <> encodeSnapshotBytes canonicalBytes
                )
            )

encodeSnapshotText :: Text.Text -> Builder.Builder
encodeSnapshotText = encodeSnapshotBytes . TextEncoding.encodeUtf8

encodeSnapshotBytes :: ByteString.ByteString -> Builder.Builder
encodeSnapshotBytes bytes =
    Builder.word64BE (fromIntegral (ByteString.length bytes))
        <> Builder.byteString bytes

draftsFor ::
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId config ->
    StepPlan ->
    IO (NonEmpty (PlanDraft scope specDigest config))
draftsFor root config plan =
    expectRight
        (planDraftsFromValidatedBuilder root config (\_ _ -> Right plan))

withAdmittedProjectPlan ::
    LifecycleProfile scope ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    StepPlan ->
    (forall planId. ProjectPlan scope specDigest planId configId cfg -> IO result) ->
    IO result
withAdmittedProjectPlan profile root config plan use = do
    drafts <- draftsFor root config plan
    action <- expectRight (withProjectPlan profile root config drafts use)
    action

snapshotFor ::
    LifecycleProfile scope ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    StepPlan ->
    IO StablePlanSnapshot
snapshotFor profile root config plan =
    withAdmittedProjectPlan profile root config plan (pure . renderSnapshot)

singletonPlan :: StepPlan
singletonPlan =
    expectStepPlan
        [ contextInitStep
            "context"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        ]

guestOnlyPlan :: StepPlan
guestOnlyPlan =
    expectStepPlan
        [ ensureStep
            "ghc"
            "ensure ghc"
            (StepFrame "guest" "Guest")
            (const (pure StepChanged))
        ]

relabelledHostPlan :: StepPlan
relabelledHostPlan =
    expectStepPlan
        [ ensureStep
            "ghc"
            "ensure ghc"
            (StepFrame "host" "Relabelled host")
            (const (pure StepChanged))
        ]

hostWithPostHandoffPlan :: StepPlan
hostWithPostHandoffPlan =
    expectStepPlan
        [ contextInitStep
            "context"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        , postHandoffStep
            "verify"
            "verify after handoff"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        ]

topologyFixturePlan :: StepPlan
topologyFixturePlan =
    expectStepPlan
        [ descendsVia
            localContext
            ( contextInitStep
                "context"
                (StepFrame "host" "Host")
                (const (pure StepChanged))
            )
        , ensureStep
            "ghc"
            "ensure ghc"
            (StepFrame "guest" "Guest")
            (const (pure StepChanged))
        ]

closedResourceFamilyPlan :: StepPlan
closedResourceFamilyPlan =
    expectStepPlan
        [ deployVMStep
            "provider"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        , copySourceStep
            "durable share"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        , ensureStep
            "docker"
            "Docker daemon"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        , projectStep
            (either error id (projectStepId "deploy-minio"))
            PreserveOnReverse
            "MinIO"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        , projectStep
            (either error id (projectStepId "deploy-registry"))
            PreserveOnReverse
            "registry"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        , deployKindStep
            "cluster"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        ]

resourceProjectionPlan :: StepPlan
resourceProjectionPlan =
    expectStepPlan
        [ descendsVia
            localContext
            ( deployVMStep
                "provider"
                (StepFrame "host" "Host")
                (const (pure StepChanged))
            )
        , projectsOperation
            "core:deploy-vm/core:copy-source/guest-alias"
            ( copySourceStep
                "durable share"
                (StepFrame "provider" "Provider")
                (const (pure StepChanged))
            )
        , deployKindStep
            "cluster"
            (StepFrame "provider" "Provider")
            (const (pure StepChanged))
        ]

chartWorkloadPlan :: Text.Text -> StepPlan
chartWorkloadPlan = chartWorkloadPlanAt "service"

chartWorkloadPlanAt :: Text.Text -> Text.Text -> StepPlan
chartWorkloadPlanAt activationFrame workloadDigest =
    expectStepPlan
        [ deployKindStep
            "cluster"
            (StepFrame "cluster" "Cluster")
            (const (pure StepChanged))
        , declaresChartWorkloadResource
            "sha256:chart"
            "demo"
            "demo-system"
            "sha256:values"
            "registry.example/demo@sha256:image"
            "workload/demo"
            workloadDigest
            activationFrame
            "api"
            ["namespace:demo-system", "deployment:demo"]
            ( deployChartStep
                "workload"
                (StepFrame "cluster" "Cluster")
                (const (pure StepChanged))
            )
        ]

serviceActivationPlan :: Text.Text -> Text.Text -> [Text.Text] -> StepPlan
serviceActivationPlan activationFrame serviceRole effects =
    expectStepPlan
        [ declaresServiceActivation
            activationFrame
            serviceRole
            effects
            ( ensureStep
                "accelerator"
                "activate accelerator service"
                (StepFrame "host" "Host")
                (const (pure StepChanged))
            )
        ]

collidingServiceActivationPlan :: StepPlan
collidingServiceActivationPlan =
    case stepPlanSteps (chartWorkloadPlanAt "shared-service-frame" "sha256:workload") of
        [cluster, chart] ->
            expectStepPlan
                [ cluster
                , declaresServiceActivation "shared-service-frame" "accelerator" ["process-spawn"] chart
                ]
        _ -> error "chart workload fixture shape changed"

chartWorkloadWithoutClusterPlan :: StepPlan
chartWorkloadWithoutClusterPlan =
    expectStepPlan
        [ declaresChartWorkloadResource
            "sha256:chart"
            "demo"
            "demo-system"
            "sha256:values"
            "registry.example/demo@sha256:image"
            "workload/demo"
            "sha256:workload"
            "service"
            "api"
            ["namespace:demo-system", "deployment:demo"]
            ( deployChartStep
                "workload"
                (StepFrame "cluster" "Cluster")
                (const (pure StepChanged))
            )
        ]

unprojectedResourcePlan :: StepPlan
unprojectedResourcePlan =
    expectStepPlan
        [ descendsVia
            localContext
            ( deployVMStep
                "provider"
                (StepFrame "host" "Host")
                (const (pure StepChanged))
            )
        , copySourceStep
            "durable share"
            (StepFrame "provider" "Provider")
            (const (pure StepChanged))
        , deployKindStep
            "cluster"
            (StepFrame "provider" "Provider")
            (const (pure StepChanged))
        ]

projectedOperationPlan :: StepPlan
projectedOperationPlan =
    expectStepPlan
        [ projectsOperation
            "core:context-init/relation"
            ( contextInitStep
                "context"
                (StepFrame "host" "Host")
                (const (pure StepChanged))
            )
        ]

callbackReplacementPlan :: StepPlan
callbackReplacementPlan =
    expectStepPlan
        [ contextInitStep
            "context"
            (StepFrame "host" "Host")
            (const (pure StepUnchanged))
        ]

framedLabelPlanA :: StepPlan
framedLabelPlanA =
    expectStepPlan
        [ contextInitStep
            "a|b:c"
            (StepFrame "frame|one" "Frame: one")
            (const (pure StepChanged))
        ]

framedLabelPlanB :: StepPlan
framedLabelPlanB =
    expectStepPlan
        [ contextInitStep
            "a"
            (StepFrame "frame|one" "b:c|Frame: one")
            (const (pure StepChanged))
        ]

sha256Text :: ByteString.ByteString -> Text.Text
sha256Text payload = Text.pack (show (Hash.hashWith Hash.SHA256 payload))

encodedWord64 :: Word64 -> ByteString.ByteString
encodedWord64 =
    LazyByteString.toStrict
        . Builder.toLazyByteString
        . Builder.word64BE

framedCount :: Text.Text -> Word64 -> ByteString.ByteString
framedCount tag count =
    LazyByteString.toStrict
        ( Builder.toLazyByteString
            ( Builder.word64BE (fromIntegral (ByteString.length bytes))
                <> Builder.byteString bytes
                <> Builder.word64BE count
            )
        )
  where
    bytes = TextEncoding.encodeUtf8 tag

hexBytes :: ByteString.ByteString -> Text.Text
hexBytes = Text.pack . concatMap byteHex . ByteString.unpack
  where
    byteHex byte =
        [ ByteStringChar8.index "0123456789abcdef" (fromIntegral (byte `div` 16))
        , ByteStringChar8.index "0123456789abcdef" (fromIntegral (byte `mod` 16))
        ]

goldenSnapshotBytesHex :: FilePath -> Text.Text
goldenSnapshotBytesHex root =
    Text.concat
        [ "484f5354424f4f5453545241502d504c414e0000000000000007"
        , hexFramedText "root"
        , hexRoot root
        , "000000000000000b737065632d646967657374"
        , "000000000000001038343033636432393734356430636239000000000000000d636f6e6669672d646967657374"
        , "00000000000000403430366337353637343137313330386530623433626239633765306135333930326466626134"
        , "35313836353635623834363265633130383361613136326663340000000000000005737465707300000000000000"
        , "01000000000000000473746570000000000000000e00000000000000076f7264696e616c000000000000000100"
        , "000000000000086964656e746974790000000000000009636f72652d73746570000000000000000c636f6e7465"
        , "78742d696e69740000000000000000000000000000000e696d706c656d656e746174696f6e0000000000000013"
        , "636f72652d696d706c656d656e746174696f6e000000000000000200000000000000086964656e746974790000"
        , "00000000000c636f6e746578742d696e6974000000000000000000000000000000087265766973696f6e000000"
        , "000000000100000000000000096f7065726174696f6e0000000000000011636f72653a636f6e746578742d696e"
        , "6974000000000000001470726f6a65637465642d6f7065726174696f6e73000000000000000100000000000000"
        , "1a636f72653a636f6e746578742d696e69742f72656c6174696f6e000000000000001270726f76696465722d72"
        , "65736f75726365730000000000000000000000000000000f63686172742d776f726b6c6f61647300000000000000000000000000000013736572766963652d61637469766174696f6e73000000000000000000000000000000056c6162656c0000000000"
        , "000007636f6e7465787400000000000000056672616d6500000000000000020000000000000002696400000000"
        , "00000004686f737400000000000000056c6162656c0000000000000004486f7374000000000000000c64657065"
        , "6e64656e636965730000000000000000000000000000000e726576657273652d706f6c69637900000000000000"
        , "0f70726f6a6563742d6d616e616765640000000000000000000000000000000f726576657273652d6164617074"
        , "6572000000000000000f70726f6a6563742d6d616e616765640000000000000002000000000000000e696d706c"
        , "656d656e746174696f6e010000000000000013636f72652d696d706c656d656e746174696f6e00000000000000"
        , "0200000000000000086964656e74697479000000000000000c636f6e746578742d696e69740000000000000000"
        , "00000000000000087265766973696f6e000000000000000100000000000000087265766973696f6e0000000000"
        , "000001000000000000000864657363656e74730000000000000000"
        ]

hexFramedText :: Text.Text -> Text.Text
hexFramedText value =
    let bytes = TextEncoding.encodeUtf8 value
     in hexBytes
            ( LazyByteString.toStrict
                ( Builder.toLazyByteString
                    ( Builder.word64BE (fromIntegral (ByteString.length bytes))
                        <> Builder.byteString bytes
                    )
                )
            )

hexRoot :: FilePath -> Text.Text
hexRoot root =
    hexBytes
        ( LazyByteString.toStrict
            ( Builder.toLazyByteString
                ( Builder.word64BE (fromIntegral (length root) * 4)
                    <> foldMap (Builder.word32BE . fromIntegral . ord) root
                )
            )
        )

expectStepPlan :: [Step] -> StepPlan
expectStepPlan = either (error . show) id . mkStepPlan

expectRight :: (Show failure) => Either failure value -> IO value
expectRight = either (fail . show) pure

joinPlan :: Either PlanError (Either PlanError value) -> Either PlanError value
joinPlan = either Left id

expectPlanAccepted :: Either PlanError () -> IO ()
expectPlanAccepted = either (assertFailure . show) pure
