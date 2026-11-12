{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module ProjectPlanSpec (surrogateDirectorySupported, tests) where

import ConditionalCase (conditionalCase)
import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import qualified Crypto.Hash as Hash
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (isLower, isSpace, ord)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (delete, isInfixOf, isPrefixOf, sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import Expect (expectRight)
import qualified Fixture
import GHC.IO.Exception (IOErrorType (InvalidArgument))
import qualified HostBootstrap.CLI.Bare as Bare
import HostBootstrap.CLI.Bare.Runtime (parseLoopbackMapping, successfulLine)
import HostBootstrap.Cluster.Lifecycle (ClusterProfile, mkTestCaseProfile, clusterKubeconfigPath, resolvePlan)
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
import HostBootstrap.Handoff (
    HandoffBindingInput (..),
    HandoffPayloadKind (NarrowedProjectConfig),
    childConfigDigest,
    freshChallenge,
    grantHandoff,
    handoffInstalledProject,
    handoffOfferWire,
    handoffPlanRevision,
    handoffScope,
    harnessHandoffScope,
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
import HostBootstrap.Harness (runWithOwnedRun)
import HostBootstrap.Harness.Ownership (protectedProjectRunOwnership, withOwnedHarnessRoot)
import HostBootstrap.Lifecycle.Mode (
    LifecycleProfile,
    ModeError (ModeAuthorityFailure, ModeEvidenceMismatch, ModeMalformedCanonicalSnapshot, ModeSnapshotMismatch),
    RecoveredProductionLifecycleProfile,
    UnboundRunLease,
    VerifiedPlanSnapshot,
    harnessActiveMode,
    harnessRootAuthority,
    harnessRootHarnessAuthority,
    harnessRootModeLease,
    harnessRootRunId,
    harnessRootUnboundLease,
    persistCanonicalPlanSnapshot,
    planSnapshotCanonicalBytes,
    planSnapshotConfigDigest,
    planSnapshotPlanDigest,
    planSnapshotRevision,
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
    verifyPlanSnapshot,
    withHarnessLifecycleProfile,
    withProductionLifecycleProfile,
    withProductionRoot,
    withRecoveredProductionLifecycleProfile,
 )
import HostBootstrap.Lift (
    ConfigDelivery (..),
    ContainerLift (..),
    ContainerPlacement (ProviderGuestContainer),
    emptyVMStack,
    inContainer,
    localContext,
 )
import HostBootstrap.ProjectPlan (
    PlanDraft,
    PlanError (..),
    PlannedResourceKind (
        ClusterResourceKind,
        DockerResourceKind,
        DurableShareResourceKind,
        ObjectStoreResourceKind,
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
    plannedStepIdentity,
    plannedStepLabel,
    plannedStepOperationKey,
    plannedStepProjectedOperationKeys,
    projectPlanProfileName,
    projectPlanProjectName,
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
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord,
    ProtectedStore,
    RecordKey,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    mkRecordName,
    openProtectedStore,
    protectedRecordBytes,
    protectedRecordVersion,
    readProtectedRecord,
    recordKeyText,
    recordTupleSeparator,
    recordVersionWord,
    withProtectedEntry,
 )
import qualified HostBootstrap.Reconcile as Reconcile (
    canonicalPlanSnapshotBytes,
    canonicalPlanSnapshotConfigDigest,
    canonicalPlanSnapshotDigest,
    canonicalPlanSnapshotFormatVersion,
    canonicalPlanSnapshotRoot,
    canonicalPlanSnapshotSpecDigest,
 )
import HostBootstrap.RoleLifecycle (
    DeclaredEffects (NoEffects),
    RoleAcquireOutcome (Acquired),
    RolePrereqOutcome (PrereqSatisfied),
    RoleProbeOutcome (ProbeReadyNow),
    RoleReleaseOutcome (Released),
    mkRoleResourceRequest,
    rolePlanDraft,
 )
import HostBootstrap.Service (
    ServiceRegistry,
    ServiceResourceBackend (..),
    emptyServiceRegistry,
    finalizedServiceVariantNames,
    serviceId,
    serviceProgramDefinition,
    serviceRoleSchemaFamilies,
    singletonServiceRegistry,
 )
import HostBootstrap.Service.Program (ServiceBackend (..))
import HostBootstrap.Step (
    CoreStepId (ContextInitId, EnsureToolId),
    ReversePolicy (PreserveOnReverse, ProjectManagedReverse),
    Step,
    StepFrame (StepFrame),
    StepIdentity (CoreStepIdentity),
    StepObservation (StepChanged, StepUnchanged),
    StepPlan,
    StepPlanError (..),
    buildImageStep,
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
import SourceGuard (
    fieldModules,
    mainLibraryStanza,
    significantHaskellLineCount,
 )
import qualified SourceGuard
import System.Directory (createDirectory, doesDirectoryExist)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeFileName, (</>))
import System.IO.Error (ioeGetErrorType)
import System.IO.Temp (withSystemTempDirectory)
import System.IO.Unsafe (unsafePerformIO)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (
    assertBool,
    assertFailure,
    testCase,
    (@?=),
 )
import Unsafe.Coerce (unsafeCoerce)

fixtureHarnessProfile :: String -> ClusterProfile
fixtureHarnessProfile = either (error . show) id . mkTestCaseProfile . Text.pack

tests :: TestTree
tests =
    testGroup
        "indexed project-plan foundation"
        [ testCase "bare plan refuses absent Harness run and pins kubectl to its plan" $
            withSystemTempDirectory "hostbootstrap-bare-values" $ \directory -> do
                cfg <- expectRight (Bare.bareInit "bare" directory (Fixture.initArgsFor Context.HostOrchestrator) :: Either String (Bare.BareConfig ()))
                rooted <- withCanonicalProjectRoot directory directory $ \root ->
                    pure (Bare.bareStepPlan "bare" root cfg)
                case rooted of
                    Right (Left EmptyStepPlan) -> pure ()
                    _ -> assertFailure "bare plan accepted a config without a Harness run"
                forM_ ["", "x/../../..", Text.replicate 49 "a", "\x4e00"] $ \badRun -> do
                    rejected <- withCanonicalProjectRoot directory directory $ \root ->
                        pure (Bare.bareStepPlan "bare" root (Bare.bareWithRunForTesting badRun cfg))
                    case rejected of
                        Right (Left EmptyStepPlan) -> pure ()
                        _ -> assertFailure "bare plan accepted an invalid Harness run key"
                accepted <- withCanonicalProjectRoot directory directory $ \root ->
                    pure (Bare.bareStepPlan "bare" root (Bare.bareWithRunForTesting "run-42" cfg))
                case accepted of
                    Right (Right _) -> pure ()
                    _ -> assertFailure "bare plan refused a valid Harness run key"
                let plan = resolvePlan "bare" directory (fixtureHarnessProfile "run-test")
                    expected = ["--kubeconfig", clusterKubeconfigPath plan]
                Bare.bareKubectlArguments plan ["version", "-o", "json"] @?= expected <> ["version", "-o", "json"]
                Bare.bareKubectlArguments plan ["get", "nodes", "-o", "name"] @?= expected <> ["get", "nodes", "-o", "name"]
        , testCase "bare command output and loopback mapping use strict values" $ do
            successfulLine "probe" (Right (ExitSuccess, "", "")) @?= Right ""
            successfulLine "probe" (Right (ExitSuccess, "one\n", "")) @?= Right "one"
            forM_ [Right (ExitSuccess, "one\ntwo\n", ""), Right (ExitSuccess, "one", ""),
                   Right (ExitSuccess, "one\n", "warning"), Right (ExitFailure 2, "one\n", "failure")] $ \answer ->
                case successfulLine "probe" answer of
                    Left _ -> pure ()
                    Right value -> assertFailure ("unexpected successful output: " <> value)
            parseLoopbackMapping "127.0.0.1:43123" @?= Right "43123"
            forM_ ["0.0.0.0:43123", "[::1]:43123", "127.0.0.1:", "127.0.0.1:4x"] $ \binding ->
                case parseLoopbackMapping binding of
                    Left _ -> pure ()
                    Right value -> assertFailure ("unexpected accepted binding: " <> value)
        , testCase "Production and exact Harness runs jointly finalize one static project definition" $
            Fixture.withFixtureInstalledProject $ \(project :: InstalledProjectIdentity projectId) ->
                withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \baseCodec ->
                    withFinalizedProjectSpec
                        ProductionScope
                        baseCodec
                        fixtureServiceRegistry
                        (\_ _ -> Right jointFinalizationPlan)
                        Fixture.refusingForwardChildPlan
                        ( \productionSpec ->
                            withSystemTempDirectory "hostbootstrap-finalized-project-spec" $ \directory -> do
                                store <- expectRight =<< openProtectedStore (directory </> "production-store")
                                production <-
                                    withProductionRoot store project ProjectUp $ \productionRoot -> do
                                        opened <-
                                            withProductionLifecycleProfile
                                                (rootScopeAuthority (productionRootAuthority productionRoot))
                                                (productionActiveMode (productionRootModeLease productionRoot))
                                                (productionRootUnboundLease productionRoot)
                                                ( \profile ->
                                                    exerciseFinalizedSpec
                                                        profile
                                                        productionSpec
                                                        directory
                                                        ( Fixture.defaultProjectConfig
                                                            (installedProjectName project)
                                                            (Text.pack directory)
                                                            Context.HostOrchestrator
                                                        )
                                                )
                                        action <- expectRight opened
                                        Right <$> action
                                (productionDigest, productionSteps) <- expectRight production
                                rootedHarness <-
                                    withCanonicalProjectRoot directory directory $ \ownershipRoot ->
                                        runWithOwnedRun
                                            ( protectedProjectRunOwnership
                                                project
                                                ownershipRoot
                                                directory
                                                (directory </> ".test_data")
                                            )
                                            ( \owned ->
                                                withOwnedHarnessRoot owned $ \_store _project harnessRoot _closeControl -> do
                                                    let authority = harnessRootHarnessAuthority harnessRoot
                                                    opened <-
                                                        withHarnessLifecycleProfile
                                                            (rootScopeAuthority (harnessRootAuthority harnessRoot))
                                                            authority
                                                            (harnessRootRunId harnessRoot)
                                                            (harnessActiveMode (harnessRootModeLease harnessRoot))
                                                            (harnessRootUnboundLease harnessRoot)
                                                            ( \profile ->
                                                                withHarnessFinalizedProjectSpec
                                                                    (V.harnessConfigAuthority authority)
                                                                    productionSpec
                                                                    ( \harnessSpec ->
                                                                        exerciseFinalizedSpec
                                                                            profile
                                                                            harnessSpec
                                                                            directory
                                                                            ( Fixture.defaultProjectConfig
                                                                                (installedProjectName project)
                                                                                (Text.pack directory)
                                                                                Context.TestHarness
                                                                            )
                                                                    )
                                                            )
                                                    action <- expectRight opened
                                                    action
                                            )
                                harness <- expectRight rootedHarness
                                (harnessDigest, harnessSteps) <- case harness of
                                    Left reason -> assertFailure reason
                                    Right (summary, Nothing) -> pure summary
                                    Right (_, Just failure) -> assertFailure ("Harness finalization cleanup failed: " <> show failure)
                                let expectedSteps =
                                        [ (CoreStepIdentity ContextInitId, "first root step")
                                        , (CoreStepIdentity (EnsureToolId "ghc"), "second tool step")
                                        ]
                                productionSteps @?= expectedSteps
                                harnessSteps @?= expectedSteps
                                productionSteps @?= harnessSteps
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
                first <-
                    expectRight $
                        withProjectPlan profile root config drafts (stablePlanSnapshotBytes . renderSnapshot)
                second <-
                    expectRight $
                        withProjectPlan profile root config drafts (stablePlanSnapshotBytes . renderSnapshot)
                first @?= second
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
                                                            ( \authority childPlan _digestBinding ->
                                                                ( childPlanAuthorityBinding authority
                                                                , stablePlanSnapshotDigest (renderSnapshot childPlan)
                                                                , projectPlanProjectName childPlan
                                                                , projectPlanProfileName childPlan
                                                                )
                                                            )
                                                    )
                                                )
                                        expectRight refined
                                observed <- expectRight configAdmission
                                handoffScope (relayBinding relay) @?= "Production"
                                pure
                                    ( observed
                                    , (relayBinding relay, planDigest, installedProjectName project, "production")
                                    )
                            )
                    (observed, expected) <- expectRight brokered
                    observed @?= expected
        , testCase "child admission refuses a signed revision other than the stable child plan digest" $
            withSnapshotPlan singletonPlan $
                \store project rootAuthority _unbound spec root parentConfig _parentDrafts parentPlan -> do
                    let codec = finalizedProjectCodec spec
                        payload = renderScopedProjectConfigBytes codec (validatedConfigValue parentConfig)
                        parentPlanDigest = stablePlanSnapshotDigest (renderSnapshot parentPlan)
                        input = HandoffBindingInput
                            { requestedSpecDigest = validatedConfigSpecDigest parentConfig
                            , requestedPayloadKind = NarrowedProjectConfig
                            , requestedPlanRevision = parentPlanDigest
                            , requestedParentFrame = "parent-frame"
                            , requestedChildFrame = "host"
                            , requestedChildConfigDigest = childConfigDigest payload
                            , requestedPhase = "execute"
                            }
                    signingKey <- expectRight
                        (projectSigningKeyFromBytes (ByteString.replicate 32 202))
                    brokered <- withRootBroker (productionHandoffScope project) store signingKey rootAuthority $ \broker -> do
                        let admitRevision revision = do
                                callbacks <- newIORef (0 :: Int)
                                (relay, token) <- expectRight =<< registerHandoffEdge broker
                                    input{requestedPlanRevision = revision}
                                offer <- expectRight (mkHandoffOffer relay payload token)
                                challenge <- freshChallenge
                                grant <- expectRight =<< grantHandoff broker offer challenge
                                handoff <- expectRight
                                    (verifyHandoff (rootBrokerVerificationKey broker)
                                        (handoffOfferWire offer) (relayBinding relay) challenge grant)
                                authenticated <- expectRight (verifiedConfigPayload handoff)
                                configAdmission <- withAuthenticatedConfigWire codec authenticated $ \wire childConfig -> do
                                    childDrafts <- expectRight (projectPlanDrafts spec root childConfig)
                                    refined <- expectRight
                                        (withVerifiedConfigHandoff ProjectUp handoff wire childConfig $ \configHandoff ->
                                            withChildProjectPlan ProjectUp configHandoff wire childConfig childDrafts $
                                                \authority childPlan _digestBinding -> do
                                                    modifyIORef' callbacks (+ 1)
                                                    pure
                                                        ( childPlanAuthorityBinding authority
                                                        , stablePlanSnapshotDigest (renderSnapshot childPlan)
                                                        , projectPlanProjectName childPlan
                                                        , projectPlanProfileName childPlan
                                                        ))
                                    -- Execute every returned observer, including an unexpected Right.
                                    case refined of
                                        Left failure -> pure (Left failure)
                                        Right action -> Right <$> action
                                outcome <- expectRight configAdmission
                                count <- readIORef callbacks
                                pure (outcome, count, relayBinding relay)
                        (matching, matchingCalls, matchingBinding) <- admitRevision parentPlanDigest
                        observed@(_, actualChildDigest, _, _) <- expectRight matching
                        observed @?= (matchingBinding, parentPlanDigest, installedProjectName project, "production")
                        matchingCalls @?= 1
                        (refused, refusedCalls, refusedBinding) <- admitRevision "signed-but-not-the-child-plan"
                        let signedRevision = handoffPlanRevision refusedBinding
                            expected = AuthorityMalformedBinding
                                ("child plan admission failed: " <> Text.pack
                                    (show (PlanHandoffEvidenceMismatch "stable plan digest" signedRevision actualChildDigest)))
                        assertBool "the actual signed revision differs from the matching admitted child digest"
                            (signedRevision /= actualChildDigest)
                        refused @?= Left expected
                        refusedCalls @?= 0
                    _ <- expectRight brokered
                    pure ()
        , testCase "an owned Harness config edge admits the exact run profile and child authority" $
            Fixture.withFixtureInstalledProject $ \(project :: InstalledProjectIdentity projectId) ->
                withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \baseCodec ->
                    withFinalizedProjectSpec ProductionScope baseCodec fixtureServiceRegistry
                        (\_ _ -> Right singletonPlan) Fixture.refusingForwardChildPlan $ \productionSpec ->
                            withSystemTempDirectory "hostbootstrap-harness-child-plan" $ \directory -> do
                                rooted <- withCanonicalProjectRoot directory directory $ \ownershipRoot ->
                                    runWithOwnedRun
                                        (protectedProjectRunOwnership project ownershipRoot directory (directory </> ".test_data")) $
                                        \owned -> withOwnedHarnessRoot owned $ \store ownedProject harnessRoot _closeControl -> do
                                            let harnessAuthority = harnessRootHarnessAuthority harnessRoot
                                                actualRun = V.harnessRunName harnessAuthority
                                                expectedProject = installedProjectName ownedProject
                                            opened <- withHarnessLifecycleProfile
                                                (rootScopeAuthority (harnessRootAuthority harnessRoot))
                                                harnessAuthority (harnessRootRunId harnessRoot)
                                                (harnessActiveMode (harnessRootModeLease harnessRoot))
                                                (harnessRootUnboundLease harnessRoot) $ \profile ->
                                                    withHarnessFinalizedProjectSpec
                                                        (V.harnessConfigAuthority harnessAuthority) productionSpec $ \spec -> do
                                                            let codec = finalizedProjectCodec spec
                                                                value = Fixture.defaultProjectConfig expectedProject
                                                                    (Text.pack directory) Context.TestHarness
                                                            rootedPlan <- withCanonicalProjectRoot
                                                                (directory </> "fixture.dhall") directory $ \root -> do
                                                                    validated <- withValidatedConfig codec value $ \_parentWire parentConfig -> do
                                                                        validatedConfigSpecDigest parentConfig @?= projectCodecSpecDigest codec
                                                                        drafts <- expectRight (projectPlanDrafts spec root parentConfig)
                                                                        action <- expectRight
                                                                            (withProjectPlan profile root parentConfig drafts $ \parentPlan -> do
                                                                                let planDigest = stablePlanSnapshotDigest (renderSnapshot parentPlan)
                                                                                    payload = renderScopedProjectConfigBytes codec value
                                                                                    input = HandoffBindingInput
                                                                                        { requestedSpecDigest = validatedConfigSpecDigest parentConfig
                                                                                        , requestedPayloadKind = NarrowedProjectConfig
                                                                                        , requestedPlanRevision = planDigest
                                                                                        , requestedParentFrame = "parent-frame"
                                                                                        , requestedChildFrame = "host"
                                                                                        , requestedChildConfigDigest = childConfigDigest payload
                                                                                        , requestedPhase = "execute"
                                                                                        }
                                                                                signingKey <- expectRight
                                                                                    (projectSigningKeyFromBytes (ByteString.replicate 32 203))
                                                                                brokered <- withRootBroker
                                                                                    (harnessHandoffScope ownedProject harnessAuthority)
                                                                                    store signingKey (harnessRootAuthority harnessRoot) $ \broker -> do
                                                                                        (relay, token) <- expectRight =<< registerHandoffEdge broker input
                                                                                        offer <- expectRight (mkHandoffOffer relay payload token)
                                                                                        challenge <- freshChallenge
                                                                                        grant <- expectRight =<< grantHandoff broker offer challenge
                                                                                        handoff <- expectRight
                                                                                            (verifyHandoff (rootBrokerVerificationKey broker)
                                                                                                (handoffOfferWire offer) (relayBinding relay) challenge grant)
                                                                                        authenticated <- expectRight (verifiedConfigPayload handoff)
                                                                                        configAdmission <- withAuthenticatedConfigWire codec authenticated $ \wire childConfig -> do
                                                                                            childDrafts <- expectRight (projectPlanDrafts spec root childConfig)
                                                                                            refined <- expectRight
                                                                                                (withVerifiedConfigHandoff ProjectUp handoff wire childConfig $ \configHandoff ->
                                                                                                    withChildProjectPlan ProjectUp configHandoff wire childConfig childDrafts $
                                                                                                        \authority childPlan _digestBinding ->
                                                                                                            ( childPlanAuthorityBinding authority
                                                                                                            , stablePlanSnapshotDigest (renderSnapshot childPlan)
                                                                                                            , projectPlanProjectName childPlan
                                                                                                            , projectPlanProfileName childPlan
                                                                                                            ))
                                                                                            expectRight refined
                                                                                        observed <- expectRight configAdmission
                                                                                        handoffScope (relayBinding relay) @?= "Harness " <> actualRun
                                                                                        handoffInstalledProject (relayBinding relay) @?= expectedProject
                                                                                        pure (observed, (relayBinding relay, planDigest, expectedProject, "harness:" <> actualRun))
                                                                                (observed@(_, childDigest, childProject, childProfile), expected) <- expectRight brokered
                                                                                observed @?= expected
                                                                                pure (childProject, childProfile, actualRun, childDigest, planDigest))
                                                                        action
                                                                    expectRight validated
                                                            expectRight rootedPlan
                                            action <- expectRight opened
                                            action
                                ownership <- expectRight rooted
                                case ownership of
                                    Left reason -> assertFailure ("Harness acquisition failed: " <> reason)
                                    Right ((childProject, childProfile, actualRun, childDigest, expectedDigest), Nothing) -> do
                                        childProject @?= installedProjectName project
                                        childProfile @?= "harness:" <> actualRun
                                        childDigest @?= expectedDigest
                                        assertBool "the real owned run name is nonempty" (not (Text.null actualRun))
                                    Right (_, Just failure) -> assertFailure
                                        ("Harness child-plan cleanup failed: " <> show failure)
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
                        pure
                            ( validatedConfigDigest otherConfig
                            , withProjectPlan profile root otherConfig drafts (const ())
                            )
                (admittedConfigDigest, outcome) <- either fail pure validated
                outcome
                    @?= Left
                        ( PlanDraftConfigurationMismatch
                            admittedConfigDigest
                            (validatedConfigDigest config)
                        )
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
                        [providerNode, shareNode, dockerNode, objectStoreNode, registryNode, clusterNode] -> do
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
                                    ObjectStoreResourceKind
                                    (plannedStepOperationKey objectStoreNode)
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
                                    , "project:deploy-object-store"
                                    , "project:deploy-registry"
                                    , "core:deploy-kind"
                                    ]
                            withPlannedResourceOfKind plan ObjectStoreResourceKind (plannedStepOperationKey providerNode) (const ())
                                @?= Left (PlanResourceKindMismatch "core:deploy-vm" "object store")
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
        , testCase "provider guest alias projection refuses a share that does not depend on the provider" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config shareBeforeProviderResourcePlan $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [shareNode, providerNode, _clusterNode] -> do
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
                                                            withProviderGuestAliasProjection plan provider share (\_ _ -> ())
                                                        )
                                            )
                            -- The absent dependency must refuse before the
                            -- intentionally absent alias declaration is checked.
                            projected
                                @?= Left (PlanDependencyEdgeMissing "core:copy-source" "core:deploy-vm")
                        other -> assertFailure ("expected share, provider, and cluster nodes, got " <> show (length other))
        , testCase "node guest alias projection checks membership before provider order and declaration" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config shareBeforeProviderResourcePlan $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [shareNode, providerNode, clusterNode] -> do
                            let reversedPrefix =
                                    joinPlan $
                                        withPlannedStepResourceOfKind
                                            clusterNode
                                            ProviderResourceKind
                                            (plannedStepOperationKey providerNode)
                                            ( \provider ->
                                                joinPlan $
                                                    withPlannedStepResourceOfKind
                                                        clusterNode
                                                        DurableShareResourceKind
                                                        (plannedStepOperationKey shareNode)
                                                        ( \share ->
                                                            withPlannedStepGuestAliasProjection clusterNode provider share (\_ _ -> ())
                                                        )
                                            )
                                outsideSharePrefix =
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
                                                            withPlannedStepGuestAliasProjection shareNode provider share (\_ _ -> ())
                                                        )
                                            )
                            reversedPrefix
                                @?= Left (PlanDependencyEdgeMissing "core:copy-source" "core:deploy-vm")
                            -- Plan-level resources reach this opener without an
                            -- earlier node-local resource lookup refusing them.
                            outsideSharePrefix
                                @?= Left (PlanNodeResourceOutsidePrefix "core:deploy-vm")
                        other -> assertFailure ("expected share, provider, and cluster nodes, got " <> show (length other))
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
                stablePlanSnapshotFormatVersion snapshot @?= 8
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
        , testCase "the shared snapshot representation preserves a genuine canonical writer input" $
            withSnapshotPlan singletonPlan $ \store project _authority unbound _spec root _config _drafts plan -> do
                let stable = renderSnapshot plan
                    canonical = Fixture.canonicalSnapshotFromProjectPlan plan
                    expectedDisplay = "CanonicalPlanSnapshot<v8, " <> Text.unpack (stablePlanSnapshotDigest stable) <> ">"
                Reconcile.canonicalPlanSnapshotFormatVersion @?= 8
                stablePlanSnapshotFormatVersion stable @?= 8
                Reconcile.canonicalPlanSnapshotRoot canonical @?= canonicalProjectRootPath root
                Reconcile.canonicalPlanSnapshotSpecDigest canonical @?= stablePlanSnapshotSpecDigest stable
                Reconcile.canonicalPlanSnapshotConfigDigest canonical @?= stablePlanSnapshotConfigDigest stable
                Reconcile.canonicalPlanSnapshotBytes canonical @?= stablePlanSnapshotBytes stable
                Reconcile.canonicalPlanSnapshotDigest canonical @?= stablePlanSnapshotDigest stable
                show canonical @?= expectedDisplay
                show stable @?= expectedDisplay
                _ <- expectRight =<< persistCanonicalPlanSnapshot unbound 1 canonical
                key <- expectRight (fixtureSnapshotKey project (unboundRunLeaseRunText unbound))
                observed <- expectRight =<< withProtectedEntry store (\session -> readProtectedRecord session key)
                record <- maybe (assertFailure "the shared canonical writer produced no snapshot") pure observed
                recordVersionWord (protectedRecordVersion record) @?= 1
                protectedRecordBytes record
                    @?= deliverySnapshotEnvelope stable (stablePlanSnapshotDigest stable) (stablePlanSnapshotBytes stable)
                before <- readAllProtectedRecords store
                callbacks <- newIORef (0 :: Int)
                verified <- verifyPlanSnapshot unbound $ \snapshot -> do
                    modifyIORef' callbacks (+ 1)
                    pure
                        ( Right
                            ( planSnapshotRevision snapshot
                            , planSnapshotSpecDigest snapshot
                            , planSnapshotPlanDigest snapshot
                            , planSnapshotConfigDigest snapshot
                            , planSnapshotCanonicalBytes snapshot
                            )
                        )
                verified
                    @?= Right
                        ( 1
                        , stablePlanSnapshotSpecDigest stable
                        , stablePlanSnapshotDigest stable
                        , Just (stablePlanSnapshotConfigDigest stable)
                        , Just (stablePlanSnapshotBytes stable)
                        )
                readIORef callbacks >>= (@?= 1)
                readAllProtectedRecords store >>= (@?= before)
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
                    @?= encodedWord64 8
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
        , testCase "length framing separates adjacent frame field boundaries" $
            withFoundation $ \_codec profile root config -> do
                forM_
                    [ ("|", ("f|x", "L"), ("f", "x|L"))
                    , ("", ("fx", "L"), ("f", "xL"))
                    ]
                    ( \(separator, (firstId, firstLabel), (secondId, secondLabel)) -> do
                        (firstId <> separator <> firstLabel) @?= (secondId <> separator <> secondLabel)
                        first <- snapshotFor profile root config (framedLabelPlan firstId firstLabel)
                        second <- snapshotFor profile root config (framedLabelPlan secondId secondLabel)
                        let firstBytes = stablePlanSnapshotBytes first
                            secondBytes = stablePlanSnapshotBytes second
                            frameRecord fid label =
                                framedCount "frame" 2
                                    <> framedText "id"
                                    <> framedText (Text.pack fid)
                                    <> framedText "label"
                                    <> framedText (Text.pack label)
                        assertBool "distinct length-framed fields collapsed" (firstBytes /= secondBytes)
                        -- Fixed field tags also distinguish these records.
                        -- Check each value's framing directly, rather than
                        -- claiming inequality alone proves its presence.
                        assertBool
                            "the first frame record lost an explicit BE64 value length"
                            (frameRecord firstId firstLabel `ByteString.isInfixOf` firstBytes)
                        assertBool
                            "the second frame record lost an explicit BE64 value length"
                            (frameRecord secondId secondLabel `ByteString.isInfixOf` secondBytes)
                    )
        , testGroup "canonical filesystem root encoding"
            [ conditionalCase
                surrogateDirectoryFamily
                surrogateDirectorySupported
                "canonical filesystem roots preserve surrogate and replacement-character identity"
                assertFilesystemRootEncoding
                assertSurrogateDirectoryRefusal
            ]
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
                            (fixtureSnapshotKey project runName)
                    observed <-
                        withProtectedEntry storeB $ \session ->
                            readProtectedRecord session key
                    either (fail . show) pure observed >>= (@?= Nothing)
                    readIORef continued >>= (@?= 0)
        , testGroup "persisted two-coordinate container delivery" deliverySnapshotCases
        , testGroup
            "exact recovered Production project plan"
            recoveredProductionProjectPlanCases
        , sourceBoundaryTests
        ]

surrogateDirectoryFamily :: [String]
surrogateDirectoryFamily = ["indexed project-plan foundation", "canonical filesystem root encoding"]

data SurrogateDirectoryCapability
    = SurrogateDirectoryAvailable
    | SurrogateDirectoryRefused FilePath IOException
    | SurrogateDirectoryProbeFailed IOException

-- The manifest and the case share one real filesystem observation. A failed
-- control or cleanup is retained as a test failure, never a filename refusal.
{-# NOINLINE surrogateDirectoryCapability #-}
surrogateDirectoryCapability :: SurrogateDirectoryCapability
surrogateDirectoryCapability = unsafePerformIO $ do
    observed <- try @IOException $
        withSystemTempDirectory "hostbootstrap-surrogate-directory" $ \directory -> do
            let control = directory </> "ascii-control"
                attemptedPath = directory </> ('r' : ['\xDC80'])
            createDirectory control
            controlExists <- doesDirectoryExist control
            if not controlExists
                then ioError (userError "the ASCII directory control was not created")
                else do
                    attempted <- try @IOException (createDirectory attemptedPath)
                    pure $ case attempted of
                        Right () -> SurrogateDirectoryAvailable
                        Left failure
                            | ioeGetErrorType failure == InvalidArgument ->
                                SurrogateDirectoryRefused attemptedPath failure
                            | otherwise -> SurrogateDirectoryProbeFailed failure
    pure (either SurrogateDirectoryProbeFailed id observed)

surrogateDirectorySupported :: Bool
surrogateDirectorySupported = case surrogateDirectoryCapability of
    SurrogateDirectoryAvailable -> True
    _ -> False

assertSurrogateDirectoryRefusal :: IO ()
assertSurrogateDirectoryRefusal = case surrogateDirectoryCapability of
    SurrogateDirectoryRefused attemptedPath failure -> do
        takeFileName attemptedPath @?= ('r' : ['\xDC80'])
        ioeGetErrorType failure @?= InvalidArgument
        putStrLn
            ( "Unsupported: createDirectory refused a lone-surrogate filename: "
                <> show attemptedPath
                <> " ("
                <> show (ioeGetErrorType failure)
                <> ")"
                <> "; DEVELOPMENT_PLAN/rationale.md#a-root-encoder-is-tested-through-a-real-filesystem-root"
            )
    SurrogateDirectoryProbeFailed failure ->
        assertFailure ("the filesystem capability probe failed: " <> show failure)
    SurrogateDirectoryAvailable ->
        assertFailure "the filesystem accepted the surrogate filename but selected its refusal branch"

assertFilesystemRootEncoding :: IO ()
assertFilesystemRootEncoding =
    withFoundation $ \_codec profile parent config -> do
        let directory = canonicalProjectRootPath parent
            surrogatePath = directory </> ('r' : ['\xDC80'])
            replacementPath = directory </> ('r' : ['\xFFFD'])
        createDirectory surrogatePath
        createDirectory replacementPath
        firstRooted <-
            withCanonicalProjectRoot (directory </> "fixture.dhall") surrogatePath $ \root -> do
                let path = canonicalProjectRootPath root
                assertBool "canonicalization lost the literal surrogate" ('\xDC80' `elem` path)
                snapshot <- snapshotFor profile root config singletonPlan
                pure (path, snapshot)
        secondRooted <-
            withCanonicalProjectRoot (directory </> "fixture.dhall") replacementPath $ \root -> do
                let path = canonicalProjectRootPath root
                assertBool "canonicalization lost the replacement character" ('\xFFFD' `elem` path)
                snapshot <- snapshotFor profile root config singletonPlan
                pure (path, snapshot)
        (firstPath, first) <- expectRight firstRooted
        (secondPath, second) <- expectRight secondRooted
        stablePlanSnapshotRoot first @?= firstPath
        stablePlanSnapshotRoot second @?= secondPath
        stablePlanSnapshotConfigDigest first @?= stablePlanSnapshotConfigDigest second
        assertBool "the distinct filesystem roots collapsed in snapshot bytes" (stablePlanSnapshotBytes first /= stablePlanSnapshotBytes second)
        assertBool "the distinct filesystem roots retained one snapshot digest" (stablePlanSnapshotDigest first /= stablePlanSnapshotDigest second)
        firstPayload <- snapshotRootPayload first
        secondPayload <- snapshotRootPayload second
        let wordsIn payload =
                [ByteString.take 4 (ByteString.drop offset payload) | offset <- [0, 4 .. ByteString.length payload - 4]]
        ByteString.length firstPayload `mod` 4 @?= 0
        ByteString.length secondPayload `mod` 4 @?= 0
        assertBool
            "the production root frame lost big-endian code point 0x0000DC80"
            (ByteString.pack [0, 0, 0xdc, 0x80] `elem` wordsIn firstPayload)
        assertBool
            "the production replacement-root frame lost big-endian code point 0x0000FFFD"
            (ByteString.pack [0, 0, 0xff, 0xfd] `elem` wordsIn secondPayload)

-- Open only the first root frame of bytes emitted by the production encoder.
snapshotRootPayload :: StablePlanSnapshot -> IO ByteString.ByteString
snapshotRootPayload snapshot = do
    let prefix =
            "HOSTBOOTSTRAP-PLAN"
                <> encodedWord64 (stablePlanSnapshotFormatVersion snapshot)
                <> framedText "root"
    framed <-
        maybe
            (assertFailure "the production snapshot has no leading canonical root frame")
            pure
            (ByteString.stripPrefix prefix (stablePlanSnapshotBytes snapshot))
    let (rawLength, afterLength) = ByteString.splitAt 8 framed
        payloadLength = ByteString.foldl' (\count byte -> count * 256 + fromIntegral byte) 0 rawLength :: Word64
    ByteString.length rawLength @?= 8
    assertBool "the production root length exceeds its available bytes" (payloadLength <= fromIntegral (ByteString.length afterLength))
    pure (ByteString.take (fromIntegral payloadLength) afterLength)

deliverySnapshotCases :: [TestTree]
deliverySnapshotCases =
    [ testCase "a two-field delivery survives public persistence and exact recovery" $
        withSnapshotPlan deliverySnapshotPlan $ \store project root unbound _spec _canonicalRoot _config _drafts plan -> do
            let stable = renderSnapshot plan
                expectedBytes = stablePlanSnapshotBytes stable
            NonEmpty.length (forward plan) @?= 2
            stablePlanSnapshotFormatVersion stable @?= 8
            assertBool
                "the persisted fixture contains its two-field delivery record"
                (framedCount "config-delivery" 2 `ByteString.isInfixOf` expectedBytes)
            persisted <- withPersistedPlanSnapshot root unbound plan (\_ _ _ _ _ -> pure ())
            either (fail . show) pure persisted
            before <- readAllProtectedRecords store
            callbacks <- newIORef (0 :: Int)
            recovered <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> assertFailure "the delivering snapshot entered the terminal callback")
                    ( \exactRoot modeLease boundLease verified bound binding recovery -> do
                        modifyIORef' callbacks (+ 1)
                        pure
                            ( withRecoveredProductionLifecycleProfile
                                exactRoot
                                modeLease
                                boundLease
                                verified
                                bound
                                binding
                                recovery
                                ( \profile ->
                                    ( planSnapshotCanonicalBytes verified
                                    , boundPlanSnapshotBytes bound
                                    , recoveredProductionProfileCanonicalBytes profile
                                    )
                                )
                            )
                    )
            recovered @?= Right (Right (Just expectedBytes, expectedBytes, expectedBytes))
            readIORef callbacks >>= (@?= 1)
            readAllProtectedRecords store >>= (@?= before)
    , refusalCase
        "a rehashed version-8 delivery record with three fields is refused"
        "the canonical config-delivery field count is malformed"
        (replaceCanonicalFragment (framedCount "config-delivery" 2) (framedCount "config-delivery" 3))
    , refusalCase
        "a rehashed version-7 header cannot admit a current two-field delivery"
        "the canonical plan version is unsupported"
        ( replaceCanonicalFragment
            ("HOSTBOOTSTRAP-PLAN" <> encodedWord64 8)
            ("HOSTBOOTSTRAP-PLAN" <> encodedWord64 7)
        )
    , refusalCase
        "a rehashed legacy version-7 delivery snapshot is refused"
        "the canonical plan version is unsupported"
        ( \bytes -> do
            let currentPrefix = framedCount "config-delivery" 2 <> framedText "write-path" <> framedText "/app/config.dhall"
                legacyPrefix =
                    framedCount "config-delivery" 3
                        <> framedText "write-path"
                        <> framedText "/app/config.dhall"
                        <> framedText "exec-path"
                        <> framedText "/app/project"
            legacy <- replaceCanonicalFragment currentPrefix legacyPrefix bytes
            replaceCanonicalFragment
                ("HOSTBOOTSTRAP-PLAN" <> encodedWord64 8)
                ("HOSTBOOTSTRAP-PLAN" <> encodedWord64 7)
                legacy
        )
    ]
  where
    refusalCase label reason mutate = testCase label $
        withSnapshotPlan deliverySnapshotPlan $ \store project root unbound _spec _canonicalRoot _config _drafts plan -> do
            let stable = renderSnapshot plan
                runName = unboundRunLeaseRunText unbound
                specDigest = stablePlanSnapshotSpecDigest stable
            NonEmpty.length (forward plan) @?= 2
            persisted <- withPersistedPlanSnapshot root unbound plan (\_ _ _ _ _ -> pure ())
            either (fail . show) pure persisted
            changedBytes <- mutate (stablePlanSnapshotBytes stable)
            assertBool "the negative fixture changes canonical bytes" (changedBytes /= stablePlanSnapshotBytes stable)
            let changedDigest = specDigest <> ":" <> sha256Text changedBytes
                epoch = Text.pack (show (brokerEpochWord (rootAuthorityEpoch root)))
            snapshotKey <- either (fail . show) pure (fixtureSnapshotKey project runName)
            leaseKey <- either (fail . show) pure (fixtureLeaseKey project runName)
            replaceSnapshotTestRecord
                store
                leaseKey
                (TextEncoding.encodeUtf8 (Text.intercalate "\t" ["bound", epoch, specDigest, changedDigest]))
            replaceSnapshotTestRecord
                store
                snapshotKey
                (deliverySnapshotEnvelope stable changedDigest changedBytes)
            before <- readAllProtectedRecords store
            callbacks <- newIORef (0 :: Int)
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> modifyIORef' callbacks (+ 1))
                    (\_ _ _ _ _ _ _ -> modifyIORef' callbacks (+ 1))
            outcome @?= Left (SnapshotVerificationError (ModeMalformedCanonicalSnapshot (recordKeyText snapshotKey) reason))
            readIORef callbacks >>= (@?= 0)
            readAllProtectedRecords store >>= (@?= before)

-- The fixture persists this actual descent, rather than a singleton recorded
-- plan with a delivery supplied only as a later reconstruction candidate.
deliverySnapshotPlan :: StepPlan
deliverySnapshotPlan =
    expectStepPlan
        [ descendsVia
            (inContainer container emptyVMStack)
            (buildImageStep "image" (StepFrame "host" "Host") (const (pure StepChanged)))
        , contextInitStep "context" (StepFrame "container" "Container") (const (pure StepChanged))
        ]
  where
    container =
        ContainerLift
            { clImage = "fixture:latest"
            , clPlacement = ProviderGuestContainer
            , clMounts = []
            , clExtraArgs = []
            , clRemoveAfter = True
            , clConfigDelivery = Just (ConfigDelivery "/app/config.dhall" "fixture projection")
            }

replaceCanonicalFragment :: ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString -> IO ByteString.ByteString
replaceCanonicalFragment old new bytes =
    case ByteString.breakSubstring old bytes of
        (_, remainder) | ByteString.null remainder ->
            assertFailure "the expected canonical fixture fragment is missing"
        (prefix, remainder) -> do
            let suffix = ByteString.drop (ByteString.length old) remainder
            assertBool "the canonical fixture fragment must be unique" (not (old `ByteString.isInfixOf` suffix))
            pure (prefix <> new <> suffix)

deliverySnapshotEnvelope :: StablePlanSnapshot -> Text.Text -> ByteString.ByteString -> ByteString.ByteString
deliverySnapshotEnvelope stable planDigest canonicalBytes =
    LazyByteString.toStrict
        ( Builder.toLazyByteString
            ( Builder.byteString "HOSTBOOTSTRAP-SNAPSHOT"
                <> Builder.word64BE 1
                <> Builder.word64BE 1
                <> encodeSnapshotText (stablePlanSnapshotSpecDigest stable)
                <> encodeSnapshotText planDigest
                <> Builder.word8 1
                <> encodeSnapshotText (stablePlanSnapshotConfigDigest stable)
                <> encodeSnapshotBytes canonicalBytes
            )
        )

fixtureLeaseKey :: InstalledProjectIdentity projectId -> Text.Text -> Either ProtectedError RecordKey
fixtureLeaseKey project runName = do
    encodedProject <- mkRecordName (installedProjectName project)
    encodedRun <- mkRecordName runName
    mkRecordKey ("lease." <> encodedProject <> recordTupleSeparator <> encodedRun)

replaceSnapshotTestRecord :: ProtectedStore -> RecordKey -> ByteString.ByteString -> IO ()
replaceSnapshotTestRecord store key bytes = do
    written <-
        withProtectedEntry store $ \session -> do
            observed <- readProtectedRecord session key
            record <- either (fail . show) (maybe (fail "the snapshot fixture record is absent") pure) observed
            compareAndSwapProtectedRecord session key (ExpectVersion (protectedRecordVersion record)) bytes
    either (fail . show) (const (pure ())) written

recoveredProductionProjectPlanCases :: [TestTree]
recoveredProductionProjectPlanCases =
    [ testCase "exact reconstruction retains one admitted plan identity" $
        withRecoveredProjectPlanFixture $ \_store _project inputs -> do
            let reconstructed = recoverProjectPlan inputs recoveredSnapshot
            case (inputs, reconstructed) of
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
    , testCase "the recovered inputs yield the exact specification at the recovered index" $
        withRecoveredProjectPlanCandidateFixture
            singletonPlan
            fixtureServiceRegistry
            ( \_store _project profile root _verified _bound _binding candidateSpec candidateConfig -> do
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
            )
    , testCase "an empty service registry still proves its digest before the specification is reindexed" $
        withRecoveredProjectPlanCandidateFixtureUsing
            emptyServiceRegistry
            singletonPlan
            emptyServiceRegistry
            ( \_store _project profile root _verified _bound _binding candidateSpec candidateConfig -> do
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
            )
    , testCase "a different independently finalized specification is refused before refinement" $
        withRecoveredProjectPlanCandidateFixture
            singletonPlan
            alternateFixtureServiceRegistry
            ( \_store _project profile root _verified _bound _binding candidateSpec candidateConfig -> do
                let expected = recoveredProductionProfileSpecDigest profile
                    observed = projectCodecSpecDigest (finalizedProjectCodec candidateSpec)
                assertBool "the independently finalized specification differs" (expected /= observed)
                assertRecoveryMismatchExact
                    "finalized specification"
                    expected
                    observed
                    ( withRecoveredProductionProjectPlanInputs
                        profile
                        root
                        candidateSpec
                        candidateConfig
                        (\_spec _refined _drafts -> error "recovered-input callback entered")
                    )
            )
    , testCase "different independently validated config bytes are refused before refinement" $
        withRecoveredProjectPlanCandidateFixture
            singletonPlan
            fixtureServiceRegistry
            ( \_store project profile root _verified _bound _binding candidateSpec _candidateConfig -> do
                let driftedValue =
                        Fixture.defaultProjectConfig
                            (installedProjectName project <> "-drift")
                            (Text.pack (canonicalProjectRootPath root))
                            Context.HostOrchestrator
                validated <-
                    withValidatedConfig
                        (finalizedProjectCodec candidateSpec)
                        driftedValue
                        ( \_wire driftedConfig -> do
                            let expected = recoveredProductionProfileConfigDigest profile
                                observed = validatedConfigDigest driftedConfig
                            assertBool "the independently validated configuration differs" (expected /= observed)
                            assertRecoveryMismatchExact
                                "validated configuration digest"
                                expected
                                observed
                                ( withRecoveredProductionProjectPlanInputs
                                    profile
                                    root
                                    candidateSpec
                                    driftedConfig
                                    (\_spec _refined _drafts -> error "recovered-input callback entered")
                                )
                        )
                either fail pure validated
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
        [ testCase "bare config decoding consumes the scoped Harness codec" $
            SourceGuard.withPackageSourceIn [] $ \root _ -> do
                source <- ByteStringChar8.unpack <$> ByteString.readFile (root </> "src" </> "HostBootstrap" </> "CLI" </> "Bare.hs")
                let tokens = SourceGuard.haskellTokens source
                assertBool "bare config uses the installed codec" ("decodeProjectCodecFile" `elem` tokens)
                assertBool "bare config requests the Harness codec" ("withHarnessProjectCodec" `elem` tokens)
                assertBool "bare config never calls Dhall inputFile" (not (SourceGuard.haskellTokens "Dhall . inputFile" `isInfixOf` tokens))
        , testCase "bare CLI delegates its relay transaction and retains failure reasons" $
            SourceGuard.withPackageSourceIn [] $ \root _ -> do
                source <- ByteStringChar8.unpack <$> ByteString.readFile (root </> "src" </> "HostBootstrap" </> "CLI" </> "Bare.hs")
                let tokens = SourceGuard.haskellTokens source
                assertBool "bare assertions do not call die" ("die" `notElem` tokens)
                assertBool "bare assertions use the tested private relay transaction" ("runtimeExposureAssertionWith" `elem` tokens)
                assertBool "lifecycle failures retain their reason" ("LifecycleFailure" `elem` tokens)
        , testCase "source matching requires code rather than line or nested block comments" $ do
            let declaration = "type role ValidatedContext nominal nominal nominal"
            containsSourceFragment declaration ("-- " <> declaration <> "\n") @?= False
            containsSourceFragment declaration ("{- outer {- " <> declaration <> " -} nested -}\n") @?= False
            containsSourceFragment declaration ("    " <> declaration <> "\n") @?= True
            containsSourceFragment declaration ("-- preceding comment\n    " <> declaration <> "\n") @?= True
        , testCase "comment stripping preserves literals pragmas newlines and token separation" $ do
            let literals = "dash = \"-- literal {- text -}\"\nbrace = '{'\n"
                pragma = "{-# LANGUAGE RankNTypes #-}\n"
                separated = "left{- outer\n{- nested -}\n-}right"
                stripped = SourceGuard.stripHaskellComments separated
            SourceGuard.stripHaskellComments literals @?= literals
            SourceGuard.stripHaskellComments pragma @?= pragma
            SourceGuard.haskellTokens pragma @?= ["{", "-#", "LANGUAGE", "RankNTypes", "#-", "}"]
            SourceGuard.haskellTokens stripped @?= ["left", "right"]
            length (filter (== '\n') stripped) @?= 2
        , testCase "ordered fragments and section bounds cannot be supplied by comments" $ do
            let code = "begin = x\nmiddle = y\nend = z\n"
                lineOnly = "-- begin = x\nmiddle = y\nend = z\n"
                blockOnly = "begin = x\n{- end = z -}\n"
                fragments = ["begin = x", "end = z"]
            sourceFragmentsInOrder fragments code @?= True
            sourceFragmentsInOrder fragments lineOnly @?= False
            sourceFragmentsInOrder fragments blockOnly @?= False
            sourceSection False "begin = x" "end = z" code @?= Just "\nmiddle = y\n"
            sourceSection True "begin = x" "end = z" code @?= Just "begin = x\nmiddle = y\n"
            sourceSection False "begin = x" "end = z" lineOnly @?= Nothing
            sourceSection True "begin = x" "end = z" blockOnly @?= Nothing
        , testCase "production scanning includes every library source root and the cluster backend" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                description <- SourceGuard.readPackageDescription
                let expectedRoots = sort
                        [ "src", "internal/authority", "internal/bare-runtime", "internal/capacity", "internal/chain-entry"
                        , "internal/cluster-backend", "internal/cluster-exposure", "internal/cluster-ownership", "internal/colima-backend", "internal/colima-ownership", "internal/effect", "internal/effect-command"
                        , "internal/handoff-implementation", "internal/harness-lifecycle", "internal/lifecycle-representation", "internal/network-port"
                        , "internal/ownership", "internal/plan-resource", "internal/provider-start", "internal/readiness", "internal/reconcile-error", "internal/reverse-root-intent", "internal/wall-observation"
                        ]
                    declaredRoots = sort
                        [ SourceGuard.repoRelativePath packageRoot (packageRoot </> directory)
                        | directory <- SourceGuard.librarySourceDirs description
                        ]
                declaredRoots @?= expectedRoots
                sources <- readProductionSources packageRoot
                let sourcePaths = [SourceGuard.repoRelativePath packageRoot path | (_, path, _) <- sources]
                    scannedRoots = [directory | directory <- expectedRoots, any ((directory <> "/") `isPrefixOf`) sourcePaths]
                scannedRoots @?= expectedRoots
                assertBool "the production scan omitted the main library's cluster backend"
                    ("HostBootstrap.Cluster.Backend.Internal" `elem` [name | (name, _, _) <- sources])
        , testCase "runner callers require a definition body and include qualified or open imports" $ do
            let runner = "runChainFromFrameWithDescentFailure"
                namedImport = "module Example where\nimport HostBootstrap.Chain (" <> runner <> ")\n"
                qualifiedCall = "module Example where\nimport qualified HostBootstrap.Chain as Chain\ncall = Chain." <> runner <> "\n"
                openCall = "module Example where\nimport HostBootstrap.Chain\ncall = " <> runner <> "\n"
                multipleClauses = namedImport <> "call True = ()\ncall False = seq " <> runner <> " ()\n"
            definitionUsesIdentifier runner namedImport >>= (@?= False)
            definitionUsesIdentifier runner (namedImport <> "-- call = " <> runner <> "\n") >>= (@?= False)
            definitionUsesIdentifier runner qualifiedCall >>= (@?= True)
            definitionUsesIdentifier runner openCall >>= (@?= True)
            definitionUsesIdentifier runner multipleClauses >>= (@?= True)
            SourceGuard.haskellDefinitionTokens "call" multipleClauses @?= Left "value definition is ambiguous: call"
        , testCase "Cabal exposes the facade and evidence leaves but hides both construction kernels" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                metadataUntrusted <- exposedOutsideTrustedImplementation cabalSource
                let exposed = metadataPublic
                    privateModules = metadataHidden
                    untrustedExposed = metadataUntrusted
                    requiredPublic =
                        [ "HostBootstrap.ProjectPlan"
                        , "HostBootstrap.ProjectPlan.Construct"
                        , "HostBootstrap.ProjectPlan.Frame"
                        , "HostBootstrap.ProjectPlan.Snapshot"
                        , "HostBootstrap.Authority.ProjectPlan"
                        ]
                assertRequiredMembers "main-library exposed modules" requiredPublic exposed
                assertBool
                    "HostBootstrap.Lifecycle.Plan is absent from the consumer-hidden implementation modules"
                    ("HostBootstrap.Lifecycle.Plan" `elem` privateModules)
                assertBool
                    "HostBootstrap.Lifecycle.Plan is exposed outside its trusted implementation owner"
                    ("HostBootstrap.Lifecycle.Plan" `notElem` untrustedExposed)
                length
                    (filter (== "HostBootstrap.ProjectPlan.Construct.Internal") privateModules)
                    @?= 1
                assertBool
                    "the finalized-spec owner is exposed outside its trusted implementation owner"
                    ("HostBootstrap.ProjectPlan.Construct.Internal" `notElem` untrustedExposed)
                fieldModules
                    "exposed-modules:"
                    "library\n  exposed-modules: HostBootstrap.Lifecycle.Plan\n"
                    @?= ["HostBootstrap.Lifecycle.Plan"]
        , testCase "post-handoff classification has one public owner and the facade delegates" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                sources <- readProductionSources packageRoot
                definitions <- traverse
                    ( \(moduleName, _path, source) -> do
                        names <- either assertFailure pure (SourceGuard.haskellDefinitionNames source)
                        pure
                            [ (moduleName, count)
                            | let count = length (filter (== "isPostHandoffStep") names)
                            , count > 0
                            ]
                    )
                    [ row
                    | row@(_moduleName, _path, source) <- sources
                    , SourceGuard.countHaskellIdentifier "isPostHandoffStep" source > 0
                    ]
                concat definitions @?= [("HostBootstrap.Step", 1)]
                publicExports <- readPublicModuleExports packageRoot
                modulesExporting "isPostHandoffStep" publicExports @?= ["HostBootstrap.Step"]
                facade <- maybe (assertFailure "the public plan facade source is absent") pure $
                    lookup "HostBootstrap.ProjectPlan" [(moduleName, source) | (moduleName, _path, source) <- sources]
                SourceGuard.countHaskellIdentifier "PostHandoffId" facade @?= 0
                delegation <- either assertFailure pure $
                    SourceGuard.haskellDefinitionTokens "plannedStepRunsAfterHandoff" facade
                assertBool
                    "the plan facade does not classify its actual retained raw step through the Step owner"
                    (containsTokenSequence ["isPostHandoffStep", ".", "plannedStepStepKernel"] delegation)
        , testCase "planned observations have no public refusal-only producer" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                -- DEVELOPMENT_PLAN/rationale.md#planned-observations-come-from-dispatch
                -- A selected node's observation is produced by its actual dispatch.
                sources <- readProductionSources packageRoot
                let forbidden = "plannedStepRefusalObservation"
                    occurrences =
                        [ (moduleName, count)
                        | (moduleName, _path, source) <- sources
                        , let count = SourceGuard.countHaskellIdentifier forbidden source
                        , count > 0
                        ]
                occurrences @?= []
                publicExports <- readPublicModuleExports packageRoot
                modulesExporting forbidden publicExports @?= []
        , testCase "the plan hashes through the shared digest owner" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                -- DEVELOPMENT_PLAN/rationale.md#plan-digests-share-one-byte-hash
                description <- SourceGuard.readPackageDescription
                planPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Lifecycle.Plan"
                digestPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Digest"
                plan <- Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile planPath
                digest <- Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile digestPath
                SourceGuard.moduleImportTokens "HostBootstrap.Digest" plan @?= Just ["sha256Hex"]
                planDefinitions <- either assertFailure pure (SourceGuard.haskellDefinitionNames plan)
                assertBool "the plan retains a local sha256Hex definition" ("sha256Hex" `notElem` planDefinitions)
                assertBool "the plan imports Crypto.Hash" (not (SourceGuard.importsModule "Crypto.Hash" plan))
                assertBool "the plan imports Data.ByteArray" (not (SourceGuard.importsModule "Data.ByteArray" plan))
                digestDefinitions <- either assertFailure pure (SourceGuard.haskellDefinitionNames digest)
                length (filter (== "sha256Hex") digestDefinitions) @?= 1
                digestExports <- requiredModuleExports "HostBootstrap.Digest" digest
                assertBool "the shared digest owner does not export sha256Hex" ("sha256Hex" `elem` digestExports)
        , testCase "object-store vocabulary has one private tag and rollout relation" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                -- DEVELOPMENT_PLAN/rationale.md#object-store-vocabulary-shares-one-tag
                sources <- readProductionSources packageRoot
                let moduleSources = [(name, source) | (name, _path, source) <- sources]
                    requireSource name = maybe (assertFailure ("missing resource vocabulary owner: " <> name)) pure (lookup name moduleSources)
                kernel <- requireSource "HostBootstrap.Lifecycle.Plan"
                resource <- requireSource "HostBootstrap.Plan.Resource"
                readinessKernel <- requireSource "HostBootstrap.Readiness.Kernel"
                readiness <- requireSource "HostBootstrap.Readiness"
                mapM_
                    ( \moduleName -> do
                        source <- requireSource moduleName
                        exports <- requiredModuleExports moduleName source
                        assertBool (moduleName <> " does not export the generic object-store resource")
                            ("ObjectStoreResource" `elem` exports)
                        assertBool (moduleName <> " exposes the private product-named tag")
                            ("MinioResource" `notElem` exports)
                    )
                    ["HostBootstrap.Lifecycle.Plan", "HostBootstrap.ProjectPlan", "HostBootstrap.Reconcile"]
                SourceGuard.countHaskellTokenSequence ["type", "ObjectStoreResource", "="] kernel @?= 0
                SourceGuard.countHaskellTokenSequence ["ObjectStoreResourceKind", "::", "PlannedResourceKind", "ObjectStoreResource"] kernel @?= 1
                resourceImports <- maybe (assertFailure "the plan does not import its shared resource identity") pure $
                    SourceGuard.moduleImportTokens "HostBootstrap.Plan.Resource" kernel
                assertBool "the plan does not import the actual object-store resource tag" ("ObjectStoreResource" `elem` resourceImports)
                privateExports <- requiredModuleExports "HostBootstrap.Plan.Resource" resource
                SourceGuard.countHaskellTokenSequence ["data", "ObjectStoreResource"] resource @?= 1
                assertBool "the private object-store resource tag is absent" ("ObjectStoreResource" `elem` privateExports)
                SourceGuard.countHaskellTokenSequence
                    ["ObjectStoreRolloutProbe", "::", "BackendProbeKey", "ObjectStoreResource", "ObjectStoreRolloutReady"]
                    readinessKernel @?= 1
                readinessResourceImports <- maybe (assertFailure "readiness does not import its shared resource identity") pure $
                    SourceGuard.moduleImportTokens "HostBootstrap.Plan.Resource" readinessKernel
                assertBool "readiness does not import the actual object-store resource tag" ("ObjectStoreResource" `elem` readinessResourceImports)
                readinessExports <- requiredModuleExports "HostBootstrap.Readiness" readiness
                assertBool "the public readiness facade does not reexport its closed probe constructors"
                    (containsTokenSequence ["BackendProbeKey", "(", "..", ")"] readinessExports)
                -- Readiness also has a qualified open import of this kernel;
                -- pin its actual unqualified constructor import independently.
                SourceGuard.countHaskellTokenSequence
                    (SourceGuard.haskellTokens "import HostBootstrap.Readiness.Kernel (BackendProbeKey (..),")
                    readiness @?= 1
                definitions <- traverse
                    ( \(moduleName, _path, source) -> do
                        names <- either assertFailure pure (SourceGuard.haskellDefinitionNames source)
                        pure (moduleName, names)
                    )
                    sources
                [name | (name, names) <- definitions, "ObjectStoreResource" `elem` names] @?= ["HostBootstrap.Plan.Resource"]
                [name | (name, names) <- definitions, "ObjectStoreRolloutProbe" `elem` names] @?= ["HostBootstrap.Readiness.Kernel"]
                [name | (name, names) <- definitions, "ObjectStoreRolloutReady" `elem` names] @?= ["HostBootstrap.Readiness.Kernel"]
                let legacyTokens = filter ("Minio" `isInfixOf`) . SourceGuard.haskellTokens
                    remaining = [(name, token) | (name, _path, source) <- sources, token <- legacyTokens source]
                legacyTokens "data MinioResource" @?= ["MinioResource"]
                legacyTokens "-- data MinioResource\n" @?= []
                legacyTokens "legacy = \"MinioResource\"" @?= ["\"MinioResource\""]
                remaining @?= []
        , testCase "current-frame entry has one private shared policy owner" $
            -- See DEVELOPMENT_PLAN/rationale.md#current-frame-entry-joins-actual-evidence.
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                description <- SourceGuard.readPackageDescription
                let policyModule = "HostBootstrap.Chain.EntryPolicy"
                    policyUnit = "hostbootstrap-core:chain-entry-internal"
                    requiredStanza name =
                        maybe (assertFailure ("missing Cabal component: " <> name)) pure (SourceGuard.namedStanza name description)
                policy <- requiredStanza "library chain-entry-internal"
                mainLibrary <- requiredStanza "library"
                testComponent <- requiredStanza "test-suite hostbootstrap-core-test"
                SourceGuard.fieldValues "visibility" policy @?= ["private"]
                SourceGuard.fieldValues "hs-source-dirs" policy @?= ["internal/chain-entry"]
                SourceGuard.fieldModules "exposed-modules" policy @?= [policyModule]
                SourceGuard.fieldModules "other-modules" policy @?= []
                sort (SourceGuard.fieldValues "build-depends" policy)
                    @?= sort (words "base >=4.18 && <5 hostbootstrap-core:authority-internal hostbootstrap-core:ownership-internal text")
                mapM_
                    ( \component -> do
                        length (filter (== policyUnit) (SourceGuard.fieldValues "build-depends" component)) @?= 1
                        assertBool "a consumer compiles the policy source again"
                            ("internal/chain-entry" `notElem` SourceGuard.fieldValues "hs-source-dirs" component)
                        mapM_
                            ( \field ->
                                assertBool
                                    ("a consumer owns or exposes another entry policy through " <> field)
                                    (policyModule `notElem` SourceGuard.fieldModules field component)
                            )
                            ["exposed-modules", "other-modules", "reexported-modules"]
                    )
                    [mainLibrary, testComponent]
                assertBool "the test component compiles a copied Main Chain"
                    ("HostBootstrap.Chain" `notElem` SourceGuard.fieldModules "other-modules" testComponent)
                sources <- SourceGuard.readLibrarySources packageRoot description
                case [(path, source) | (name, path, source) <- sources, name == policyModule] of
                    [(path, source)] -> do
                        SourceGuard.repoRelativePath packageRoot path
                            @?= "internal/chain-entry/HostBootstrap/Chain/EntryPolicy.hs"
                        requiredModuleExports policyModule source >>= (@?= ["validateCurrentFrameEntry"])
                        assertBool "the entry policy imports Main or a testing authority producer"
                            (all (`elem` ["Data.List", "Data.List.NonEmpty", "Data.Text", "HostBootstrap.Authority.Kernel", "HostBootstrap.Protected"]) (SourceGuard.haskellImports source))
                    _ -> assertFailure "the entry policy has no unique library source"
                definitions <- traverse
                    ( \(name, _, source) -> do
                        names <- either assertFailure pure (SourceGuard.haskellDefinitionNames source)
                        pure (name, names)
                    )
                    sources
                [name | (name, names) <- definitions, "validateCurrentFrameEntry" `elem` names] @?= [policyModule]
                [name | (name, _, source) <- sources, SourceGuard.importsModule policyModule source] @?= ["HostBootstrap.Chain"]
                publicExports <- readPublicModuleExports packageRoot
                modulesExporting "validateCurrentFrameEntry" publicExports @?= []
        , testCase "the snapshot representations have one private shared owner" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                description <- SourceGuard.readPackageDescription
                let coreModule = "HostBootstrap.Lifecycle.Snapshot.Core"
                    coreUnit = "hostbootstrap-core:lifecycle-representation-internal"
                    requiredStanza name =
                        maybe (assertFailure ("missing Cabal component: " <> name)) pure (SourceGuard.namedStanza name description)
                representation <- requiredStanza "library lifecycle-representation-internal"
                mainLibrary <- requiredStanza "library"
                testComponent <- requiredStanza "test-suite hostbootstrap-core-test"
                SourceGuard.fieldValues "visibility" representation @?= ["private"]
                SourceGuard.fieldValues "hs-source-dirs" representation @?= ["internal/lifecycle-representation"]
                SourceGuard.fieldModules "exposed-modules" representation
                    @?= ["HostBootstrap.Lifecycle.Execution.Core", coreModule]
                SourceGuard.fieldModules "other-modules" representation @?= []
                mapM_
                    ( \component ->
                        length (filter (== coreUnit) (SourceGuard.fieldValues "build-depends" component)) @?= 1
                    )
                    [mainLibrary, testComponent]
                mapM_
                    ( \field ->
                        assertBool
                            ("the main library owns or exposes the private snapshot core through " <> field)
                            (coreModule `notElem` SourceGuard.fieldModules field mainLibrary)
                    )
                    ["exposed-modules", "other-modules", "reexported-modules"]
                assertBool
                    "the test component compiles another snapshot core copy"
                    (coreModule `notElem` SourceGuard.fieldModules "other-modules" testComponent)
                sources <- SourceGuard.readLibrarySources packageRoot description
                case [(path, source) | (name, path, source) <- sources, name == coreModule] of
                    [(path, source)] -> do
                        SourceGuard.repoRelativePath packageRoot path
                            @?= "internal/lifecycle-representation/HostBootstrap/Lifecycle/Snapshot/Core.hs"
                        assertBool
                            "the snapshot representation imports only primitive data vocabulary"
                            (all (`elem` ["Data.ByteString", "Data.Text", "Data.Word"]) (SourceGuard.haskellImports source))
                    _ -> assertFailure "the shared snapshot core has no unique library source"
                definitions <-
                    traverse
                        ( \(name, _, source) -> do
                            names <- either assertFailure pure (SourceGuard.haskellDefinitionNames source)
                            pure (name, names)
                        )
                        sources
                mapM_
                    ( \representationName ->
                        [name | (name, names) <- definitions, representationName `elem` names] @?= [coreModule]
                    )
                    ["CanonicalPlanSnapshot", "StablePlanSnapshot", "canonicalPlanSnapshotFormatVersion"]
                sort [name | (name, _, source) <- sources, SourceGuard.importsModule coreModule source]
                    @?= ["HostBootstrap.Lifecycle.Plan", "HostBootstrap.ProjectPlan"]
        , testCase "the execution state has one private shared owner" $
            -- See DEVELOPMENT_PLAN/rationale.md#interpreter-state-has-one-private-production-representation.
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                description <- SourceGuard.readPackageDescription
                let coreModule = "HostBootstrap.Lifecycle.Execution.Core"
                    coreUnit = "hostbootstrap-core:lifecycle-representation-internal"
                    requiredStanza name =
                        maybe (assertFailure ("missing Cabal component: " <> name)) pure (SourceGuard.namedStanza name description)
                representation <- requiredStanza "library lifecycle-representation-internal"
                components <- traverse requiredStanza
                    ["library", "test-suite hostbootstrap-core-test", "test-suite hostbootstrap-provider-live-linux-cpu"]
                SourceGuard.fieldValues "visibility" representation @?= ["private"]
                SourceGuard.fieldValues "hs-source-dirs" representation @?= ["internal/lifecycle-representation"]
                mapM_
                    ( \component -> do
                        length (filter (== coreUnit) (SourceGuard.fieldValues "build-depends" component)) @?= 1
                        mapM_
                            ( \field ->
                                assertBool
                                    ("a consumer owns or exposes another execution core through " <> field)
                                    (coreModule `notElem` SourceGuard.fieldModules field component)
                            )
                            ["exposed-modules", "other-modules", "reexported-modules"]
                    )
                    components
                sources <- SourceGuard.readLibrarySources packageRoot description
                case [(path, source) | (name, path, source) <- sources, name == coreModule] of
                    [(path, source)] -> do
                        SourceGuard.repoRelativePath packageRoot path
                            @?= "internal/lifecycle-representation/HostBootstrap/Lifecycle/Execution/Core.hs"
                        assertBool
                            "the execution representation imports a second library identity"
                            (all (`elem` ["Data.ByteString", "Data.IORef", "Data.Text", "Data.Word"]) (SourceGuard.haskellImports source))
                        exports <- requiredModuleExports coreModule source
                        mapM_
                            ( \representationName -> do
                                assertBool (representationName <> " is absent") (representationName `elem` exports)
                                assertBool
                                    (representationName <> " exposes its constructor")
                                    (not (containsTokenSequence [representationName, "("] exports))
                            )
                            ["CarriedResource", "ResourceCarrierCore", "StepRuntimeCore"]
                    _ -> assertFailure "the shared execution core has no unique library source"
                definitions <-
                    traverse
                        ( \(name, _, source) -> do
                            names <- either assertFailure pure (SourceGuard.haskellDefinitionNames source)
                            pure (name, names)
                        )
                        sources
                mapM_
                    ( \representationName ->
                        [name | (name, names) <- definitions, representationName `elem` names] @?= [coreModule]
                    )
                    ["CarriedResource", "ResourceCarrierCore", "newResourceCarrierCore", "StepRuntimeCore", "newStepRuntimeCore"]
                [name | (name, _, source) <- sources, SourceGuard.importsModule coreModule source]
                    @?= ["HostBootstrap.Lifecycle.Execution.Internal"]
        , testCase "exactly the audited production modules import the plan kernel" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                sources <- readProductionSources packageRoot
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
                            , "HostBootstrap.ProjectPlan.Snapshot"
                            , "HostBootstrap.Authority.ProjectPlan"
                            , "HostBootstrap.Cluster.Budget"
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
                        if moduleName == "HostBootstrap.Command.LifecycleEntry"
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
                runnerUses <- traverse
                    ( \(moduleName, _path, source) -> do
                        called <- definitionUsesIdentifier "runChainFromFrameWithDescentFailure" source
                        pure [moduleName | called]
                    )
                    [ row
                    | row@(moduleName, _path, source) <- sources
                    , moduleName /= "HostBootstrap.Chain"
                    , SourceGuard.countHaskellIdentifier "runChainFromFrameWithDescentFailure" source > 0
                    ]
                let fixedRunnerCallers = sort (concat runnerUses)
                fixedRunnerCallers @?= ["HostBootstrap.Command.LifecycleEntry"]
        , testCase "the plan foundation depends only on the pure lift-context vocabulary" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                let foundationalModules =
                        [ "HostBootstrap.Step"
                        , "HostBootstrap.ProjectPlan"
                        , "HostBootstrap.Lifecycle.Plan"
                        ]
                foundationalSources <-
                    traverse
                        ( \moduleName -> do
                            source <- readModuleSource packageRoot moduleName
                            pure (moduleName, source)
                        )
                        foundationalModules
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
                chainSource <- readModuleSource packageRoot "HostBootstrap.Chain"
                assertBool
                    "Chain does not import the effectful HostBootstrap.Lift module"
                    (SourceGuard.importsModule "HostBootstrap.Lift" chainSource)
        , testCase "static and finalized project specifications retain their exact indices" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                cliSource <- readModuleSource packageRoot "HostBootstrap.CLI"
                constructSource <-
                    readModuleSource packageRoot "HostBootstrap.ProjectPlan.Construct"
                internalSource <-
                    readModuleSource packageRoot "HostBootstrap.ProjectPlan.Construct.Internal"
                let cli = normalizeHaskellSource cliSource
                    construct = normalizeHaskellSource constructSource
                    internal = normalizeHaskellSource internalSource
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                cliPath <- requiredModulePath packageRoot "HostBootstrap.CLI"
                constructPath <- requiredModulePath packageRoot "HostBootstrap.ProjectPlan.Construct"
                internalPath <- requiredModulePath packageRoot "HostBootstrap.ProjectPlan.Construct.Internal"
                cliBytes <- ByteString.readFile cliPath
                constructBytes <- ByteString.readFile constructPath
                internalBytes <- ByteString.readFile internalPath
                let cliSource = Text.unpack (TextEncoding.decodeUtf8 cliBytes)
                    constructSource = Text.unpack (TextEncoding.decodeUtf8 constructBytes)
                    internalSource = Text.unpack (TextEncoding.decodeUtf8 internalBytes)
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources packageRoot
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                constructExports <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan.Construct"
                        constructSource
                internalExports <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan.Construct.Internal"
                        internalSource
                publicExports <- readPublicModuleExports packageRoot
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
                    cli = normalizeHaskellSource cliSource
                    internal = normalizeHaskellSource internalSource
                    kernel = normalizeHaskellSource kernelSource
                    exposed = metadataPublic
                    privateModules = metadataHidden
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
                    internalSignificant = significantHaskellLineCount internalSource
                    -- Dated 2026-11-01 attribution before this ownership adoption:
                    -- Construct 631 / Internal 226 plus CLI and the old 394 + 618
                    -- baseline/later 46 + 5 + 10 + 3 + 8 + 4 allowances yielded 216
                    -- source lines and one metadata line, 217 total, below 400.
                    -- That shared-file arithmetic is historical evidence, not
                    -- a live freeze of unrelated child-admission code.
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
                -- DEVELOPMENT_PLAN/rationale.md#forward-child-freezes-cover-owned-declarations
                forwardingSource <- requiredSourceSectionFrom
                    "the five finalized-spec forwarding declarations"
                    "withFinalizedProjectSpec ::"
                    "projectPlanStepPlan ::"
                    constructSource
                let forwardingNames =
                        [ "withFinalizedProjectSpec"
                        , "withHarnessFinalizedProjectSpec"
                        , "withFinalizedProjectSpecParts"
                        , "finalizedProjectCodec"
                        , "finalizedProjectServices"
                        ]
                declaredForwarders <- either assertFailure pure
                    (SourceGuard.haskellDefinitionNames forwardingSource)
                declaredForwarders @?= sort forwardingNames
                forwardingClauses <- forM forwardingNames $ \name -> do
                    clauses <- either assertFailure pure
                        (SourceGuard.haskellDefinitionClauseTokens name forwardingSource)
                    length clauses @?= 1
                    pure (name, clauses)
                let forwardingBytes = LazyByteString.toStrict
                        (Aeson.encode (SourceGuard.haskellTokens forwardingSource, forwardingClauses))
                sha256Text forwardingBytes
                    @?= "c49bb152f01599b443a774dc506b11655665f209a31f3ab11b2b14f38c2326bd"
                sha256Text internalBytes
                    @?= "821e9b1deb79a23ae62339022d86aee874a0a1f3e02bf4f91204ae596d9cadb3"
                internalSignificant @?= 226
                assertBool "shared CLI lost the installed projector surface" (cliSignificant >= 424)
                cabalAttribution @?= 1
        , testCase "planned-forward handoff is exact, inert, hidden, acyclic, and frozen" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                handoffPath <- requiredModulePath packageRoot "HostBootstrap.ProjectPlan.Handoff.Internal"
                handoffBytes <- ByteString.readFile handoffPath
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                let handoffSource = Text.unpack (TextEncoding.decodeUtf8 handoffBytes)
                    handoff = normalizeHaskellSource handoffSource
                sources <- readProductionSources packageRoot
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                metadataUntrusted <- exposedOutsideTrustedImplementation cabalSource
                handoffExports <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan.Handoff.Internal"
                        handoffSource
                publicExports <- readPublicModuleExports packageRoot
                let exposed = metadataPublic
                    untrustedExposed = metadataUntrusted
                    privateModules = metadataHidden
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
                    "the planned-forward package owner is exposed outside its trusted implementation owner"
                    ("HostBootstrap.ProjectPlan.Handoff.Internal" `notElem` untrustedExposed)
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
                    "oneLayer context = case liftLayers context of [_] -> True _ -> False"
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
                    @?= "e56df2633605bd76186b246881ff7b2a8f911c9f3c6cdd431008c7e63819c29d"
                significantHaskellLineCount handoffSource @?= 339
                assertBool
                    "the forward-package owner crossed the hard 400-line split boundary"
                    (significantHaskellLineCount handoffSource < 400)
        , testCase "the shared immediate-target projection is VLC-free, exact, hidden, and acyclic" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                planPath <- requiredModulePath packageRoot "HostBootstrap.Lifecycle.Plan"
                projectionPath <- requiredModulePath packageRoot "HostBootstrap.ProjectPlan.Projection.Internal"
                planBytes <- ByteString.readFile planPath
                projectionBytes <- ByteString.readFile projectionPath
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                let planSource = Text.unpack (TextEncoding.decodeUtf8 planBytes)
                    projectionSource =
                        Text.unpack (TextEncoding.decodeUtf8 projectionBytes)
                    plan = normalizeHaskellSource planSource
                    projection = normalizeHaskellSource projectionSource
                sources <- readProductionSources packageRoot
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                metadataUntrusted <- exposedOutsideTrustedImplementation cabalSource
                projectionExports <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan.Projection.Internal"
                        projectionSource
                publicExports <- readPublicModuleExports packageRoot
                let exposed = metadataPublic
                    untrustedExposed = metadataUntrusted
                    privateModules = metadataHidden
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
                    projectionVocabularyUsers =
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
                    "the shared projection kernel is exposed outside its trusted implementation owner"
                    ("HostBootstrap.ProjectPlan.Projection.Internal" `notElem` untrustedExposed)
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
                -- The exhaustive classifier consumes the descriptive root error;
                -- projection producers and importers are pinned independently above.
                projectionVocabularyUsers
                    @?= [ "HostBootstrap.Lifecycle.Plan"
                        , "HostBootstrap.ProjectPlan.Handoff.Internal"
                        , "HostBootstrap.ProjectPlan.Projection.Internal"
                        , "HostBootstrap.Reconcile"
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
                    , "[(child, rawRoute)] | [_] <- liftLayers rawRoute ->"
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
                    , "containerPayloadMatches route payload | [ViaContainer container] <- liftLayers route ="
                    , "TextEncoding.encodeUtf8 (cdPayload delivery) == payload"
                    , "Nothing -> refusal \"container handoff has no canonical config delivery\""
                    , "| otherwise = Right ()"
                    , "withoutConfigDelivery route | [ViaContainer _] <- liftLayers route = mapTerminalContainer (\\container -> container{clConfigDelivery = Nothing}) route"
                    , "| otherwise = route"
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
                    @?= "252742d3ba09fa228f8ddc17ab7c1a099cc2bd0810a8aab0a1bfc2ccd9e17c8a"
                significantHaskellLineCount projectionSource @?= 281
        , testCase "the recursive rooted plan catalog is nominal, hidden, fold-only, and inert" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                catalogPath <- requiredModulePath packageRoot "HostBootstrap.Lifecycle.RootedPlan"
                catalogBytes <- ByteString.readFile catalogPath
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                let catalogSource = Text.unpack (TextEncoding.decodeUtf8 catalogBytes)
                    catalog = normalizeHaskellSource catalogSource
                sources <- readProductionSources packageRoot
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                metadataUntrusted <- exposedOutsideTrustedImplementation cabalSource
                catalogExports <-
                    requiredModuleExports
                        "HostBootstrap.Lifecycle.RootedPlan"
                        catalogSource
                publicExports <- readPublicModuleExports packageRoot
                let exposed = metadataPublic
                    untrustedExposed = metadataUntrusted
                    privateModules = metadataHidden
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
                    "the recursive catalog is exposed outside its trusted implementation owner"
                    ("HostBootstrap.Lifecycle.RootedPlan" `notElem` untrustedExposed)
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
                    @?= "6f38f4a0c3656f3f229ba6f8302e025378a84041b286f26d98a2bb8e80cd17f2"
                catalogSignificant @?= 421
                assertBool
                    "the recursive catalog owner crossed the hard 425-line split boundary"
                    (catalogSignificant < 425)
        , testCase "the rooted frame session is root-selected, hidden, nominal, and request-inert" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                rootedPath <- requiredModulePath packageRoot "HostBootstrap.Lifecycle.Rooted"
                rootedSource <- readFile rootedPath
                sessionSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Session"
                catalogSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.RootedPlan"
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources packageRoot
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                rootedExports <-
                    requiredModuleExports "HostBootstrap.Lifecycle.Rooted" rootedSource
                openerSource <-
                    requiredSourceSection
                        "the root opening"
                        "withRootOpenedFrameSessionKernel ::"
                        "withAttachedRootedFrameSessionKernel ::"
                        rootedSource
                attachSource <-
                    requiredSourceSection
                        "the OpenFrame attachment"
                        "withAttachedRootedFrameSessionKernel ::"
                        "withRootedFrameOpeningKernel ::"
                        rootedSource
                eliminatorSource <-
                    requiredSourceSection
                        "the fixed-unit session eliminator"
                        "withRootedFrameSessionKernel ::"
                        "rootedFrameSessionDomain ::"
                        rootedSource
                publicExports <- readPublicModuleExports packageRoot
                let rooted = normalizeHaskellSource rootedSource
                    opener = normalizeHaskellSource openerSource
                    attach = normalizeHaskellSource attachSource
                    eliminator = normalizeHaskellSource eliminatorSource
                    exposed = metadataPublic
                    privateModules = metadataHidden
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                authoritySource <-
                    readModuleSource packageRoot "HostBootstrap.Authority.FailedUp.Internal"
                rootedSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Rooted"
                entrySource <-
                    readModuleSource packageRoot "HostBootstrap.Command.LifecycleEntry"
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                authorityExports <-
                    requiredModuleExports
                        "HostBootstrap.Authority.FailedUp.Internal"
                        authoritySource
                let authority = normalizeHaskellSource authoritySource
                    rooted = normalizeHaskellSource rootedSource
                    entry = normalizeHaskellSource entrySource
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
                    "case entry of RootUpLifecycleEntry root _ _ _ _ _ _ catalog -> withFailedUpUnwindAuthorityKernel root catalog failed report binding reached unresolved use"
                    entry
                mainLibrary <- maybe (assertFailure "the main library stanza is absent") pure (mainLibraryStanza cabalSource)
                assertBool "the failed-Up authority module is built but not exposed"
                    ( "HostBootstrap.Authority.FailedUp.Internal" `elem` fieldModules "other-modules" mainLibrary
                        && "HostBootstrap.Authority.FailedUp.Internal" `notElem` fieldModules "exposed-modules" mainLibrary
                        && "HostBootstrap.Authority.FailedUp.Internal" `notElem` fieldModules "reexported-modules" mainLibrary
                    )
                publicExports <- readPublicModuleExports packageRoot
                modulesExporting "FailedUpUnwindAuthority" publicExports @?= []
                assertBool
                    "the three sprint-owned additions stay within their coherent budget"
                    ( significantHaskellLineCount authoritySource
                        + SourceGuard.countHaskellIdentifier "withFailedRootedFrameSessionKernel" rootedSource
                        + SourceGuard.countHaskellIdentifier "withFailedUpUnwindAuthorityForEntryKernel" entrySource
                        < 400
                    )
        , testCase "the rooted opening signs the root's own coordinates and records before it releases" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                rootedSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Rooted"
                runtimeSource <-
                    readModuleSource packageRoot "HostBootstrap.Handoff.Runtime"
                relaySource <-
                    readModuleSource packageRoot "HostBootstrap.Handoff.Relay"
                sources <- readProductionSources packageRoot
                runtimeExports <-
                    requiredModuleExports "HostBootstrap.Handoff.Runtime" runtimeSource
                openingSource <-
                    requiredSourceSection
                        "the rooted frame opening"
                        "withRootedFrameOpeningKernel ::"
                        "withRootedFrameSessionKernel ::"
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
                        "relayedBrokerLinkKernel ::"
                        relaySource
                serviceSource <-
                    requiredSourceSection
                        "the rooted lifecycle endpoint shape"
                        "type RootedLifecycleService ="
                        "data BrokerLink scope brokerGeneration = BrokerLink"
                        relaySource
                publicExports <- readPublicModuleExports packageRoot
                let opening = normalizeHaskellSource openingSource
                    rootArm = normalizeHaskellSource rootArmSource
                    callSite = normalizeHaskellSource callSiteSource
                    endpoint = normalizeHaskellSource endpointSource
                    service = normalizeHaskellSource serviceSource
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
                    ( "maxRootedRequesterComponents = 256" `isInfixOf` normalizeHaskellSource rootedSource
                        && "maxRootedRequesterComponentBytes = 4096"
                            `isInfixOf` normalizeHaskellSource rootedSource
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                executorSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.FrameExecutor"
                gateSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Prepared.Internal"
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources packageRoot
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                executorExports <-
                    requiredModuleExports "HostBootstrap.Lifecycle.FrameExecutor" executorSource
                openingSource <-
                    requiredSourceSection
                        "the frame executor opening"
                        "withOpenedFrameExecutorKernel ::"
                        "withFrameExecutorRequestKernel ::"
                        executorSource
                requestSource <-
                    requiredSourceSection
                        "the frame executor request builder"
                        "withFrameExecutorRequestKernel ::"
                        "withAdvancedFrameExecutorKernel ::"
                        executorSource
                advanceSource <-
                    requiredSourceSection
                        "the frame executor advance"
                        "withAdvancedFrameExecutorKernel ::"
                        "withExecutedFrameNodeKernel ::"
                        executorSource
                executionSource <-
                    requiredSourceSection
                        "the frame executor local execution"
                        "withExecutedFrameNodeKernel ::"
                        "verifiedResponse ::"
                        executorSource
                publicExports <- readPublicModuleExports packageRoot
                let executor = normalizeHaskellSource executorSource
                    opening = normalizeHaskellSource openingSource
                    request = normalizeHaskellSource requestSource
                    advance = normalizeHaskellSource advanceSource
                    execution = normalizeHaskellSource executionSource
                    exposed = metadataPublic
                    privateModules = metadataHidden
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
                    , "pure ( mintPreparedGate (GatePlanDigest packagePlan) (GateOperationKey operation) (GateSession packageSession) (GateFence generation) (GateAttempt attempt) (GateJournalVersion journalVersion) )"
                    ]
                    execution
                assertContains
                    "one helper is the only route from signed bytes to a response"
                    "verifiedResponse key request signed = either (Left . executorFailure . Text.pack . handoffErrorMessage) Right (withVerifiedRootedLifecycleResponse key request signed id)"
                    executor
                assertContains
                    "the gate package decode is canonical rather than merely well shaped"
                    "\"is not a canonical gate package\""
                    (normalizeHaskellSource gateSource)
                assertContains
                    "the gate list count is checked rather than trusted"
                    "\"does not carry the number of gate packages it declares\""
                    (normalizeHaskellSource gateSource)
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                childSource <-
                    readModuleSource packageRoot "HostBootstrap.Command.Child"
                routeSource <-
                    readModuleSource packageRoot "HostBootstrap.Handoff.Process.Route"
                cliSource <- readModuleSource packageRoot "HostBootstrap.CLI"
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources packageRoot
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                childExports <- requiredModuleExports "HostBootstrap.Command.Child" childSource
                activationExtension <-
                    requiredSourceSection
                        "worked-demo activation relay extension"
                        "activationRuntime <- newStepRuntime carrier"
                        "let opened = openWith carrier runtime link nonce"
                        childSource
                let child = normalizeHaskellSource childSource
                    exposed = metadataPublic
                    privateModules = metadataHidden
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
                    (normalizeHaskellSource routeSource)
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                routeSource <-
                    readModuleSource packageRoot "HostBootstrap.Handoff.Process.Route"
                runtimeSource <-
                    readModuleSource packageRoot "HostBootstrap.Handoff.Runtime"
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources packageRoot
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                routeExports <-
                    requiredModuleExports "HostBootstrap.Handoff.Process.Route" routeSource
                derivationSource <-
                    requiredSourceSection
                        "the process route derivation"
                        "withForwardLifecycleProcessRouteKernel ::"
                        "sanitizedLaunch :: LiftContext -> Text -> Text -> [Text] -> Either Text AdmittedLaunch"
                        routeSource
                launchSource <-
                    requiredSourceSection
                        "the process route launch grammar"
                        "sanitizedLaunch :: LiftContext"
                        "withLifecycleProcessRouteLaunchKernel ::"
                        routeSource
                openingSource <-
                    requiredSourceSection
                        "the lifecycle child opening"
                        "withLifecycleChildOpeningKernel ::"
                        "verifiedResponse ::"
                        routeSource
                publicExports <- readPublicModuleExports packageRoot
                let route = normalizeHaskellSource routeSource
                    runtime = normalizeHaskellSource runtimeSource
                    derivation = normalizeHaskellSource derivationSource
                    launch = normalizeHaskellSource launchSource
                    opening = normalizeHaskellSource openingSource
                    exposed = metadataPublic
                    privateModules = metadataHidden
                    importers moduleName =
                        sort
                            [ importer
                            | (importer, _path, source) <- sources
                            , SourceGuard.importsModule moduleName source
                            ]
                filter (/= ",") routeExports
                    @?= [ "LifecycleProcessRoute"
                        , "ChannelInteractivity"
                        , "("
                        , ".."
                        , ")"
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
                    , "ChannelInteractivity"
                    , "withForwardLifecycleProcessRouteKernel"
                    , "withRecoveryLifecycleProcessRouteKernel"
                    , "withLifecycleProcessRouteLaunchKernel"
                    , "withLifecycleChildOpeningKernel"
                    ]
                assertContains
                    "the sealed route carries seven nominal roles"
                    "type role LifecycleProcessRoute nominal nominal nominal nominal nominal nominal nominal"
                    route
                -- The route type, the two-case channel the launch names, the
                -- three admitted results that used to be anonymous tuples, and
                -- the two wrappers that separate admitted text from any other
                -- text. Nothing else here is allowed to become a type.
                assertContains
                    "the channel a launch asks for is a two-case type rather than a boolean"
                    "data ChannelInteractivity = InteractiveChannel | NoninteractiveChannel"
                    route
                mapM_
                    (\declaration -> assertContains "the route's named results" declaration route)
                    [ "data AdmittedLaunch = AdmittedLaunch HostTool [Text] ChannelInteractivity"
                    , "data AdmittedEdge = AdmittedEdge Text Text AdmittedLaunch"
                    , "data AdmittedLayers = AdmittedLayers [LiftLayer] ChannelInteractivity"
                    , "newtype ValidatedArgument = ValidatedArgument {admittedText :: Text}"
                    , "newtype ValidatedPath = ValidatedPath {admittedPathText :: Text}"
                    ]
                SourceGuard.countHaskellIdentifier "data" routeSource @?= 5
                SourceGuard.countHaskellIdentifier "newtype" routeSource @?= 2
                assertBool
                    "the only Bool left is the predicate `require` takes, never a threaded result"
                    ( SourceGuard.countHaskellIdentifier "Bool" routeSource == 1
                        && "require :: Text -> Bool -> Either Text ()" `isInfixOf` route
                    )
                assertContains
                    "the edge is minted by a derivation rather than named"
                    "( forall parent child. LifecycleProcessRoute scope rootPlanId brokerGeneration catalogId parent child verb -> IO (Either Text ()) ) -> IO (Either Text ())"
                    derivation
                assertFragmentsInOrder
                    "both routes are derived from a package rather than assembled from arguments"
                    [ "withCatalogForwardProcessInputsKernel package $ \\route input _payload ->"
                    , "case derive verb \"execute\" (withoutConfigDelivery route) input targetBinary of"
                    , "Right (AdmittedEdge parent child (AdmittedLaunch tool argv interactivity))"
                    , "use (LifecycleProcessRoute verb parent child tool argv interactivity)"
                    , "derive verb \"teardown\" (withoutConfigDelivery route) input targetBinary"
                    ]
                    derivation
                assertFragmentsInOrder
                    "the edge is the binding input's own and its phase is checked before a launch is rendered"
                    [ "require \"the admitted edge joins one frame to itself\" (parent /= child)"
                    , "(requestedPhase input == phase)"
                    , "launch <- sanitizedLaunch route child targetBinary (subcommand verb)"
                    , "pure (AdmittedEdge parent child launch)"
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
                    , "folded [ViaContainer admitted] \"\" inner InteractiveChannel"
                    , "folded [ViaVM vm] targetBinary inner NoninteractiveChannel"
                    , "folded [ViaLimaVM vm] targetBinary inner NoninteractiveChannel"
                    , "folded [ViaWsl2VM vm] targetBinary inner NoninteractiveChannel"
                    , "AdmittedLayers admitted interactivity <- validateComposedLayers child layers targetBinary"
                    , "folded admitted targetBinary inner interactivity"
                    , "HOSTBOOTSTRAP_DIRECT_CONTAINER=linux-gpu"
                    , "HOSTBOOTSTRAP_CURRENT_FRAME=\" <> Text.unpack (admittedText frame)"
                    , "++ placementArgs"
                    , "route <- case liftContextFromLayers layers of"
                    , "Left failure -> Left (routeFailure (\"the sanitized lift context is invalid: \" <> Text.pack failure))"
                    , "Right context -> Right context"
                    , "case foldLeaf route (lifecycleProcessLeaf"
                    , "DispatchTool tool argv -> Right"
                    ]
                    launch
                assertFragmentsInOrder
                    "a composed terminal container receives the same admitted protocol-channel arguments"
                    [ "go [ViaContainer container] = do"
                    , "admitted <- admittedContainer child container"
                    , "pure (AdmittedLayers [ViaContainer admitted] InteractiveChannel)"
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
                    "admitted text leaves the grammar as its own type, and a path is admitted text that is also absolute"
                    [ "sanitizedPath :: Text -> Text -> Either Text ValidatedPath"
                    , "admitted <- admittedText <$> sanitizedArgument label value"
                    , "pure (ValidatedPath admitted)"
                    , "sanitizedArgument :: Text -> Text -> Either Text ValidatedArgument"
                    , "pure (ValidatedArgument value)"
                    ]
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                gateSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Prepared.Internal"
                rootedSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Rooted.Node"
                sessionOwnerSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Rooted"
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources packageRoot
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                gateExports <-
                    requiredModuleExports "HostBootstrap.Lifecycle.Prepared.Internal" gateSource
                nodeExports <-
                    requiredModuleExports "HostBootstrap.Lifecycle.Rooted.Node" rootedSource
                producerSource <-
                    requiredSourceSection
                        "the durable node-grant producer"
                        "withPreparedRootedNodeGrantKernel ::"
                        "withSettledRootedNodeKernel ::"
                        rootedSource
                settlementSource <-
                    requiredSourceSection
                        "the durable node settlement"
                        "withSettledRootedNodeKernel ::"
                        "publishExactRow :: ProtectedStore -> Text -> RecordKey -> ByteString -> IO (Either Text Word64)"
                        rootedSource
                publicExports <- readPublicModuleExports packageRoot
                let gate = normalizeHaskellSource gateSource
                    producer = normalizeHaskellSource producerSource
                    settlement = normalizeHaskellSource settlementSource
                    exposed = metadataPublic
                    privateModules = metadataHidden
                    sites name =
                        [ (moduleName, count)
                        | (moduleName, _path, sourceBody) <- sources
                        , let count = SourceGuard.countHaskellIdentifier name sourceBody
                        , count > 0
                        ]
                filter (/= ",") gateExports
                    @?= [ "GatePlanDigest"
                        , "("
                        , ".."
                        , ")"
                        , "GateOperationKey"
                        , "("
                        , ".."
                        , ")"
                        , "GateSession"
                        , "("
                        , ".."
                        , ")"
                        , "GateFence"
                        , "("
                        , ".."
                        , ")"
                        , "GateAttempt"
                        , "("
                        , ".."
                        , ")"
                        , "GateJournalVersion"
                        , "("
                        , ".."
                        , ")"
                        , "GateCatalogIdentity"
                        , "("
                        , ".."
                        , ")"
                        , "GateFrame"
                        , "("
                        , ".."
                        , ")"
                        , "GateSupersessionGeneration"
                        , "("
                        , ".."
                        , ")"
                        , "PreparedGate"
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
                    (normalizeHaskellSource rootedSource)
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                receiptSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Rooted.Receipt"
                sessionOwnerSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Rooted"
                nodeOwnerSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Rooted.Node"
                relaySource <-
                    readModuleSource packageRoot "HostBootstrap.Handoff.Relay"
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- readProductionSources packageRoot
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                receiptExports <-
                    requiredModuleExports "HostBootstrap.Lifecycle.Rooted.Receipt" receiptSource
                reportSource <-
                    requiredSourceSection
                        "the terminal report"
                        "withRootedTerminalReportKernel ::"
                        "withRootedReceiptConfirmationKernel ::"
                        receiptSource
                confirmSource <-
                    requiredSourceSection
                        "the receipt confirmation"
                        "withRootedReceiptConfirmationKernel ::"
                        "withTerminalRootedSession ::"
                        receiptSource
                callSiteSource <-
                    requiredSourceSection
                        "the terminal receipt call site"
                        "withRootedTerminalReceiptKernel ::"
                        "linkSignActivation ::"
                        relaySource
                publicExports <- readPublicModuleExports packageRoot
                let report = normalizeHaskellSource reportSource
                    confirm = normalizeHaskellSource confirmSource
                    callSite = normalizeHaskellSource callSiteSource
                    exposed = metadataPublic
                    privateModules = metadataHidden
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
                    (normalizeHaskellSource receiptSource)
                assertContains
                    "each answer stays inside its own closed paired family"
                    "\"only a paired \" <> family <> \" or Refused response answers this rooted terminal request\""
                    (normalizeHaskellSource receiptSource)
                assertContains
                    "a signed Refused is read as an outcome rather than minted"
                    "Left (receiptFailure (\"the rooted terminal request was refused: \" <> detail))"
                    (normalizeHaskellSource receiptSource)
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
        , testCase "reconciliation consumes the admitted plan without another producer" $
            -- See DEVELOPMENT_PLAN/rationale.md#reconciliation-takes-the-admitted-plan.
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                description <- SourceGuard.readPackageDescription
                sources <- SourceGuard.readLibrarySources packageRoot description
                let removedFunctions =
                        [ "withLifecyclePlan"
                        , "withLifecyclePlanForConfig"
                        , "lifecyclePlanFromProjectPlan"
                        , "lifecyclePlanDigest"
                        , "lifecyclePlanSnapshot"
                        , "lifecyclePlanSnapshotBytes"
                        , "lifecyclePlanConfigDigest"
                        , "lifecyclePlanFrames"
                        , "lifecyclePlanSteps"
                        , "configFreeDigest"
                        , "compatibilityLifecyclePlanRoot"
                        , "carryManagedResource"
                        , "mintCarriedResource"
                        ]
                forM_ sources $ \(name, _, source) ->
                    forM_ removedFunctions $ \removed ->
                        assertBool (name <> " retains " <> removed) (removed `notElem` SourceGuard.haskellTokens source)
                case [source | (name, _, source) <- sources, name == "HostBootstrap.Reconcile"] of
                    [source] -> do
                        definitions <- either assertFailure pure (SourceGuard.haskellDefinitionNames source)
                        exports <- requiredModuleExports "HostBootstrap.Reconcile" source
                        assertBool "reconciliation defines an independent plan" ("LifecyclePlan" `notElem` definitions)
                        assertBool "reconciliation exports an independent plan" ("LifecyclePlan" `notElem` exports)
                    _ -> assertFailure "reconciliation has no unique library source"
                case [source | (name, _, source) <- sources, name == "HostBootstrap.Lifecycle.Plan"] of
                    [source] -> do
                        definitions <- either assertFailure pure (SourceGuard.haskellDefinitionNames source)
                        exports <- requiredModuleExports "HostBootstrap.Lifecycle.Plan" source
                        assertBool "admitted construction lost its actual encoder" ("canonicalPlanSnapshot" `elem` definitions)
                        assertBool "the raw encoder escapes its construction owner" ("canonicalPlanSnapshot" `notElem` exports)
                    _ -> assertFailure "the admitted plan kernel has no unique library source"
        , testCase "the kernel keeps projected nodes abstract" $
            -- See DEVELOPMENT_PLAN/rationale.md#each-projected-node-checks-its-descriptor.
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                kernelSource <- readModuleSource packageRoot "HostBootstrap.Lifecycle.Plan"
                kernelExports <- requiredModuleExports "HostBootstrap.Lifecycle.Plan" kernelSource
                assertBool "PlannedStep is absent from the kernel export list" ("PlannedStep" `elem` kernelExports)
                assertBool
                    "kernel importers can construct a projected node"
                    (not (containsTokenSequence ["PlannedStep", "("] kernelExports))
                assertBool "the retained-step accessor is absent" ("plannedStepStepKernel" `elem` kernelExports)
                facadeSource <- readModuleSource packageRoot "HostBootstrap.ProjectPlan"
                facadeExports <- requiredModuleExports "HostBootstrap.ProjectPlan" facadeSource
                assertBool "the raw-step accessor escapes the facade" ("plannedStepStepKernel" `notElem` facadeExports)
        , testCase "the pure facade exposes only the abstract stable snapshot view" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                kernelSource <- readModuleSource packageRoot "HostBootstrap.Lifecycle.Plan"
                kernelExports <- requiredModuleExports "HostBootstrap.Lifecycle.Plan" kernelSource
                assertBool
                    "IndexedPlanSnapshot is absent from the kernel export list"
                    ("IndexedPlanSnapshot" `elem` kernelExports)
                assertBool
                    "IndexedPlanSnapshot constructors are available to kernel importers"
                    (not (containsTokenSequence ["IndexedPlanSnapshot", "("] kernelExports))
                assertBool
                    "the canonical encoder escapes its admitted-plan construction owner"
                    ("canonicalPlanSnapshot" `notElem` kernelExports)
                facadeSource <- readModuleSource packageRoot "HostBootstrap.ProjectPlan"
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

                publicExports <- readPublicModuleExports packageRoot
                modulesExporting "IndexedPlanSnapshot" publicExports @?= []
                modulesExporting "canonicalPlanSnapshot" publicExports @?= []
                mapM_
                    ( \(moduleName, exports) -> do
                        mapM_
                            ( \representationName ->
                                assertBool
                                    (moduleName <> " exposes constructors of " <> representationName)
                                    (not (containsTokenSequence [representationName, "("] exports))
                            )
                            ["CanonicalPlanSnapshot", "StablePlanSnapshot"]
                        assertBool
                            (moduleName <> " reexports the private snapshot core")
                            (not (containsTokenSequence (SourceGuard.haskellTokens "module HostBootstrap.Lifecycle.Snapshot.Core") exports))
                    )
                    publicExports
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

                sources <- readProductionSources packageRoot
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                modeSource <- readModuleSource packageRoot "HostBootstrap.Lifecycle.Mode"
                sessionSource <- readModuleSource packageRoot "HostBootstrap.Lifecycle.Session"
                snapshotSource <-
                    readModuleSource packageRoot "HostBootstrap.ProjectPlan.Snapshot"
                intentModuleSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.ReverseRootIntent"
                schema <-
                    requiredSourceSection
                        "private reverse-root schema"
                        "data ReverseRootIntent projectId sourceBrokerGeneration verb where"
                        "reverseRootIntentMagic ::"
                        intentModuleSource
                codec <-
                    requiredSourceSectionFrom
                        "private reverse-root codec"
                        "reverseRootIntentMagic ::"
                        "collect (remaining - 1) trailing (field : fields)"
                        intentModuleSource
                sourceEliminator <-
                    requiredSourceSection
                        "strict reverse-root source-record eliminator"
                        "withReverseRootSourceRecordsKernel ::"
                        "withLifecycleCursor ::"
                        sessionSource
                -- The recovery finalizer is a later consumer of this shared
                -- module. Freeze the reverse protocol's own references only;
                -- a build without that consumer needs no placeholder section.
                protocolSource <-
                    if "data ProductionClosureAuthorization" `Text.isInfixOf` Text.pack modeSource
                        then do
                            finalizer <- requiredSourceSection "Production closure consumer" "data ProductionClosureAuthorization" "data ProductionInvocationCompleted projectId specDigest planDigest brokerGeneration" modeSource
                            pure (Text.unpack (Text.replace (Text.pack finalizer) "" (Text.pack (SourceGuard.stripHaskellComments modeSource))))
                        else pure modeSource
                let sealedSchema = normalizeHaskellSource schema
                    canonicalCodec = normalizeHaskellSource codec
                    eliminator = normalizeHaskellSource sourceEliminator
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
                (\expectedCounts -> [(name, SourceGuard.countHaskellIdentifier name protocolSource) | (name, _) <- expectedCounts] @?= expectedCounts)
                    [ ("ReverseRootDownPending", 3)
                    , ("ReverseRootDestroyPending", 4)
                    , ("ReverseRootDownCommitted", 3)
                    , ("ReverseRootDestroyCommitted", 3)
                    , ("ReverseRootDownTerminal", 8)
                    , ("ReverseRootDestroyTerminal", 7)
                    , ("encodeReverseRootIntent", 8)
                    , ("decodeReverseRootIntent", 12)
                    , ("reverseRootIntentKey", 7)
                    , ("reverseRootIntentKeyForName", 4)
                    ]
                mapM_
                    (\name -> SourceGuard.countHaskellIdentifier name modeSource @?= 0)
                    [ "withReauthorizedBoundPlanSnapshotKernel"
                    , "advanceReverseRootIntent"
                    ]
                mapM_
                    (\source -> SourceGuard.countHaskellIdentifier "unsafeCoerce" source @?= 0)
                    [modeSource, sessionSource, snapshotSource]
                publicExports <- readPublicModuleExports packageRoot
                modulesExporting "ReverseRootIntent" publicExports @?= []
                modulesExporting "AcquisitionJournalAdmission" publicExports @?= []
                sources <- readProductionSources packageRoot
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
                intentOwners @?= ["HostBootstrap.Lifecycle.ReverseRootIntent"]
                admissionOwners @?= ["HostBootstrap.Lifecycle.Plan"]
                eliminatorSites
                    @?= [ "HostBootstrap.Lifecycle.Mode"
                        , "HostBootstrap.Lifecycle.Session"
                        ]
                -- The private test seam forwards the existing allocator and
                -- reifier; it introduces no production allocation owner.
                filter (/= "HostBootstrap.Authority.Testing") freshBrokerSites
                    @?= [ "HostBootstrap.Authority.Kernel"
                        , "HostBootstrap.Lifecycle.Mode"
                        ]
                authorityTesting <- maybe (assertFailure "the private authority fixture source is missing") pure
                    (lookup "HostBootstrap.Authority.Testing" [(name, body) | (name, _, body) <- sources])
                fixtureExports <- requiredModuleExports "HostBootstrap.Authority.Testing" authorityTesting
                fixtureImports <- maybe (assertFailure "the authority fixture must explicitly import the kernel") pure
                    (SourceGuard.moduleImportTokens "HostBootstrap.Authority.Kernel" authorityTesting)
                fixtureImports @?= fixtureExports
                filter (== "withFreshBrokerEpochKernel") fixtureExports @?= ["withFreshBrokerEpochKernel"]
                filter (== "withFreshBrokerEpochKernel") fixtureImports @?= ["withFreshBrokerEpochKernel"]
                SourceGuard.countHaskellIdentifier "withFreshBrokerEpochKernel" authorityTesting @?= 2
                filter (== "withReifiedAllocatedBrokerEpochKernel") fixtureExports @?= ["withReifiedAllocatedBrokerEpochKernel"]
                filter (== "withReifiedAllocatedBrokerEpochKernel") fixtureImports @?= ["withReifiedAllocatedBrokerEpochKernel"]
                SourceGuard.countHaskellIdentifier "withReifiedAllocatedBrokerEpochKernel" authorityTesting @?= 2
                -- The whole module is one explicit export list and one matching
                -- import, so it contains no allocation call or forwarding body.
                SourceGuard.haskellTokens authorityTesting
                    @?= SourceGuard.haskellTokens "module HostBootstrap.Authority.Testing ("
                        <> fixtureExports
                        <> SourceGuard.haskellTokens ") where import HostBootstrap.Authority.Kernel ("
                        <> fixtureImports
                        <> [")"]
                -- Mode chooses the intent key. The shared redo coordinator may
                -- validate that key in its closed finalization descriptor.
                filter (/= "HostBootstrap.Lifecycle.Transaction") reverseKeyLiteralSites
                    @?= ["HostBootstrap.Lifecycle.Mode"]
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                modeSource <- readModuleSource packageRoot "HostBootstrap.Lifecycle.Mode"
                transitionSource <-
                    requiredSourceSectionFrom
                        "reverse-root resume/redo transition"
                        "withResumedExistingBoundReverseRootKernel ::"
                        "data HarnessBoundRecovery projectId runId"
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
                        "data HarnessBoundRecovery projectId runId"
                        modeSource
                pendingSource <-
                    requiredSourceSection
                        "reverse-root Pending transition"
                        "commitPending common encodeCommitted"
                        "finishCommitted"
                        engineSource
                promotionSource <-
                    requiredSourceSection
                        "terminal Down to Destroy admission"
                        "    promoteDown ::"
                        "    drive ::"
                        engineSource
                committedSource <-
                    requiredSourceSection
                        "reverse-root Committed convergence"
                        "        finishCommitted\n            common\n            target\n            nextModeVersion"
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
                let wrapper = normalizeHaskellSource wrapperSource
                    engine = normalizeHaskellSource engineSource
                    pending = normalizeHaskellSource pendingSource
                    promotion = normalizeHaskellSource promotionSource
                    committed = normalizeHaskellSource committedSource
                    common = normalizeHaskellSource commonSource
                    suffix = normalizeHaskellSource suffixSource
                    existingRoot = normalizeHaskellSource existingRootSource
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
                        ( "Down recognizes only Destroy as the opposite intent and a settled Destroy as terminal"
                        , "ProjectDown -> case decodeReverseRootIntent ProjectDestroy bytes of Just ReverseRootDestroyTerminal{} -> Just True Just _ -> Just False Nothing -> Nothing"
                        , engine
                        )
                    ,
                        ( "Destroy recognizes only Down as the opposite intent"
                        , "ProjectDestroy -> False <$ decodeReverseRootIntent ProjectDown bytes"
                        , engine
                        )
                    ,
                        ( "an opposite in-flight intent is refused, a settled Destroy is terminal for Down, and anything else is malformed"
                        , "Just True -> pure (Left ModeReverseRootTerminal) Just False -> pure (Left ModeReverseRootInProgress) Nothing -> pure (Left (ModeMalformedRecord (recordKeyText intentKey)))"
                        , engine
                        )
                    ,
                        ( "the Pending intent has its exact verb-specific durable version"
                        , "not (reverseRootPhaseVersion verb 1 pendingVersion)"
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
                        , "readback <- exactWordRecord session intentKey (pendingVersion + 1) bytes"
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
                    "terminal Down verifies its exact authority before publishing following Destroy"
                    [ "ReverseRootDownTerminal common target modeVersion modeBytes leaseVersion leaseBytes"
                    , "recordVersionWord (protectedRecordVersion retained) == 3"
                    , "verifyAllSessionsClosed session plan"
                    , "validateCommon session location nextCommon"
                    , "exactWordRecord session key modeVersion modeBytes"
                    , "exactWordRecord session (leaseLocationLeaseKey location) leaseVersion leaseBytes"
                    , "requireBytes \"terminal Down mode\" (encodeMode WireProduction target) modeBytes"
                    , "requireBytes \"terminal Down lease\" (encodeLease (LeaseBound target spec plan)) leaseBytes"
                    , "if target > source then Right () else mismatch \"terminal Down epoch\" \"greater than source\" (showWord target)"
                    , "Right () | ProjectDown <- verb -> pure (Left ModeReverseRootTerminal)"
                    , "Right () | ProjectDestroy <- verb"
                    , "ReverseRootDestroyPending nextCommon"
                    , "compareAndSwapProtectedRecord session intentKey (ExpectVersion (protectedRecordVersion retained)) bytes"
                    , "exactWordRecord session intentKey 4 bytes"
                    ]
                    promotion
                SourceGuard.countHaskellIdentifier "compareAndDeleteProtectedRecord" promotionSource @?= 0
                mapM_
                    (\(label, fragment) -> assertContains label fragment engine)
                    [
                        ( "the promotion fallback refuses any other opposite or non-terminal row"
                        , "_ -> case oppositeIntent (protectedRecordBytes retained) of"
                        )
                    ,
                        ( "terminal Destroy admits only version 3 or 6"
                        , "not (reverseRootPhaseVersion ProjectDestroy 3 (recordVersionWord (protectedRecordVersion intentRecord))) = mismatchIO \"terminal Destroy version\" \"3 or 6\""
                        )
                    ,
                        ( "terminal Destroy refuses an exhausted lease version"
                        , "leaseVersion == maxBound = mismatchIO \"terminal lease version\" \"below maxBound\" \"maxBound\""
                        )
                    ,
                        ( "terminal Destroy requires a closed journal, closed lease, and absent mode"
                        , "isNothing held && state == ClosedProject && target > source"
                        )
                    ]
                -- The Committed section opens at finishCommitted's definition, so its
                -- ordering check reads its own guard, not commitAllocated's Pending one.
                SourceGuard.countHaskellIdentifier "commitAllocated" committedSource @?= 0
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
                    [ "intentRead <- exactWordRecord session intentKey (recordVersionWord (protectedRecordVersion retainedIntent))"
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
                SourceGuard.countHaskellIdentifier "validateCommon" engineSource @?= 6
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
                sources <- readProductionSources packageRoot
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
                publicExports <- readPublicModuleExports packageRoot
                modulesExporting "withResumedExistingBoundReverseRootKernel" publicExports
                    @?= ["HostBootstrap.Lifecycle.Mode"]
                modulesExporting "resumeExistingBoundReverseRootKernel" publicExports @?= []
                modulesExporting "withExistingBoundReverseRootTransition" publicExports @?= []
        , testCase "reverse-root fresh admission is strict, exact, sole, and Snapshot-only" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                modeSource <- readModuleSource packageRoot "HostBootstrap.Lifecycle.Mode"
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
                        "withResumedExistingBoundReverseRootKernel ::"
                        modeSource
                engineSource <-
                    requiredSourceSection
                        "shared reverse-root transition engine"
                        "withExistingBoundReverseRootTransition ::"
                        "data HarnessBoundRecovery projectId runId"
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
                let signature = normalizeHaskellSource freshSignatureSource
                    fresh = normalizeHaskellSource freshSource
                    engine = normalizeHaskellSource engineSource
                    liveSource = normalizeHaskellSource liveSourceSection
                    liveRows = normalizeHaskellSource liveRowsSection
                    pending = normalizeHaskellSource pendingSection
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
                        , "validateBoundRunLeaseAcquisitionJournal (rootAuthorityVerb sourceRoot) sourceBound sourceJournal"
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
                sources <- readProductionSources packageRoot
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
                publicExports <- readPublicModuleExports packageRoot
                modulesExporting "withFreshExistingBoundReverseRootKernel" publicExports
                    @?= ["HostBootstrap.Lifecycle.Mode"]
        , testCase "reverse-root Snapshot selection is strict, liveness-scoped, and caller-sealed" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                snapshotSource <-
                    readModuleSource packageRoot "HostBootstrap.ProjectPlan.Snapshot"
                facadeSource <-
                    case dropThrough
                        "withReauthorizedBoundPlanSnapshotKernel ::"
                        (SourceGuard.stripHaskellComments snapshotSource) of
                        Nothing ->
                            assertFailure "the reverse-root Snapshot facade section is absent"
                                >> pure ""
                        Just section -> pure ("withReauthorizedBoundPlanSnapshotKernel ::" <> section)
                resumeBranch <-
                    requiredSourceSection
                        "reverse-root Snapshot resume branch"
                        "Left failure | failure == ModeReverseRootInProgress"
                        "Left failure ->"
                        facadeSource
                targetSignature <-
                    requiredSourceSection
                        "reverse-root Snapshot target callback"
                        "( forall targetBrokerGeneration targetSpecDigest targetPlanDigest targetPlanId."
                        "IO (Either SnapshotError result)"
                        facadeSource
                let facade = normalizeHaskellSource facadeSource
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
                        ( "fromMode maps a terminal reverse root to its typed Snapshot outcome"
                        , "fromMode (Left ModeReverseRootTerminal) = Left SnapshotReverseRootTerminal"
                        , facade
                        )
                    ,
                        ( "InProgress or absent-mode selector failures resume, and a resume that finds no retained intent under an absent mode keeps the absent-mode failure"
                        , "case selected of Left failure | failure == ModeReverseRootInProgress || failure == ModeWrongMode \"production\" \"absent\" -> do resumed <- withResumedExistingBoundReverseRootKernel admission store project verb use pure $ case (failure, fromMode resumed) of (ModeWrongMode \"production\" \"absent\", Left (SnapshotVerificationError ModeReverseRootInProgress)) -> Left (SnapshotVerificationError failure) (_, outcome) -> outcome Left failure -> pure (Left (SnapshotVerificationError failure)) Right outcome -> pure outcome"
                        , facade
                        )
                    ,
                        ( "the sole liveness extent contains the complete selector"
                        , "held <- withRunLiveness store livenessName select"
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
                    , "failure == ModeReverseRootInProgress || failure == ModeWrongMode \"production\" \"absent\""
                    , "withResumedExistingBoundReverseRootKernel"
                    , "underLiveness = case mkRecordName (installedProjectName project) of"
                    , "Left failure -> pure (Left (SnapshotLivenessFailure failure))"
                    , "Right livenessName -> do"
                    , "withRunLiveness store livenessName select"
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
                    ]
                -- Once as a resume trigger and once in the no-retained-intent mapping.
                SourceGuard.countHaskellIdentifier "ModeReverseRootInProgress" facadeSource @?= 2
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
                sources <- readProductionSources packageRoot
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
                publicExports <- readPublicModuleExports packageRoot
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                entrySource <-
                    readModuleSource packageRoot "HostBootstrap.Command.LifecycleEntry"
                sessionSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Session"
                modeSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Mode"
                constructSource <-
                    readModuleSource packageRoot "HostBootstrap.ProjectPlan.Construct"
                reverseEntry <-
                    requiredSourceSection
                        "reverse-root lifecycle-entry producer"
                        "withRootProjectReverseLifecycleEntry ::"
                        "runRootProjectUpLifecycleEntry ::"
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
                        "withPreparedRootReverseDescentKernel ::"
                        reverseEntry
                targetCursorKernel <-
                    requiredSourceSection
                        "reverse-root target cursor kernel"
                        "withReverseRootTargetLifecycleCursorKernel ::"
                        "withLifecycleCursor ::"
                        sessionSource
                acquisitionGate <-
                    requiredSourceSection
                        "generic acquisition journal gate"
                        "withAcquisitionJournal ::"
                        "validateBoundRunLeaseAcquisitionJournal ::"
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
                let entry = normalizeHaskellSource reverseEntry
                    source = normalizeHaskellSource sourceCallback
                    target = normalizeHaskellSource targetCallback
                    sealer = normalizeHaskellSource sealerSection
                    cursor = normalizeHaskellSource targetCursorKernel
                    acquisition = normalizeHaskellSource acquisitionGate
                    recovered = normalizeHaskellSource recoveredPlanGate
                    constructors = normalizeHaskellSource constructorSection
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
                        ( "authorization consumes the callback-derived Teardown cursor and verified installed identity"
                        , "ProjectAuthority.authorizeRootProject targetRoot targetVerb targetVerified targetBound targetBinding targetLease targetPlan journal teardownCursor lifecycleContext project"
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
                        , "advance = case seedPhase of Prepare | recordVersionWord sourceVersion == 1 -> case validateLifecycleCursorRequest journal frame verb of"
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
                    (\name -> SourceGuard.countHaskellIdentifier name entrySource @?= 8)
                    ["RootDownLifecycleEntry", "RootDestroyLifecycleEntry"]
                sources <- readProductionSources packageRoot
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
                        , ("HostBootstrap.Lifecycle.Session", 4)
                        ]
                publicExports <- readPublicModuleExports packageRoot
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
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Session.Testing"
                SourceGuard.countHaskellIdentifier
                    "withReverseRootTargetLifecycleCursorKernel"
                    sessionTesting
                    @?= 0
        , testCase "the reverse-descent substrate is hidden, nominal, and durably ordered" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                internalSource <-
                    readModuleSource packageRoot "HostBootstrap.Teardown.Internal"
                teardownSource <-
                    readModuleSource packageRoot "HostBootstrap.Teardown"
                entrySource <-
                    readModuleSource packageRoot "HostBootstrap.Command.LifecycleEntry"
                familySource <-
                    requiredSourceSectionFrom
                        "the prepared reverse-descent family"
                        "data\n    ReverseDescent"
                        "withReverseDescentLiftContextKernel ::"
                        internalSource
                signatureSource <-
                    requiredSourceSectionFrom
                        "the prepared reverse-descent kernel signature"
                        "withPreparedReverseDescentKernel ::"
                        "withPreparedReverseDescentKernel admission ="
                        internalSource
                admissionSource <-
                    requiredSourceSection
                        "the prepared reverse-descent admission body"
                        "withPreparedReverseDescentKernel admission ="
                        "withBoundReverseDescentKernel ::"
                        internalSource
                adapterVerifierSource <-
                    requiredSourceSectionFrom
                        "the canonical reverse-adapter verifier"
                        "withVerifiedReverseAdapterKernel ::"
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
                let internal = normalizeHaskellSource internalSource
                    family = normalizeHaskellSource familySource
                    signature = normalizeHaskellSource signatureSource
                    admission = normalizeHaskellSource admissionSource
                    adapterVerifier = normalizeHaskellSource adapterVerifierSource
                    teardown = normalizeHaskellSource teardownSource
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
                sources <- readProductionSources packageRoot
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
                    @?= [ ("HostBootstrap.Teardown.Internal", 3)
                        ]
                importers "HostBootstrap.Teardown.Internal"
                    @?= [ "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.Handoff.Completion"
                        , "HostBootstrap.Handoff.Process"
                        , "HostBootstrap.Handoff.Relay"
                        ]
                publicExports <- readPublicModuleExports packageRoot
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
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                let exposedModules = metadataPublic
                    otherModules = metadataHidden
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                entrySource <-
                    readModuleSource packageRoot "HostBootstrap.Command.LifecycleEntry"
                internalSource <-
                    readModuleSource packageRoot "HostBootstrap.Teardown.Internal"
                commandSource <-
                    readModuleSource packageRoot "HostBootstrap.Command"
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
                        "withPreparedRootReverseDescentKernel ::"
                        entrySource
                producerSignature <-
                    requiredSourceSectionFrom
                        "root prepared-descent producer signature"
                        "withPreparedRootReverseDescentKernel ::"
                        "withPreparedRootReverseDescentKernel entry descent use ="
                        entrySource
                producerBody <-
                    requiredSourceSection
                        "root prepared-descent producer body"
                        "withPreparedRootReverseDescentKernel entry descent use ="
                        "withPreparedFailedUpReverseDescentKernel ::"
                        entrySource
                refusalSection <-
                    requiredSourceSection
                        "root prepared-descent refusal"
                        "    refused ="
                        "withPreparedFailedUpReverseDescentKernel ::"
                        entrySource
                entryExports <-
                    maybe
                        (assertFailure "HostBootstrap.Command.LifecycleEntry has no explicit export list")
                        pure
                        ( SourceGuard.moduleExportTokens
                            "HostBootstrap.Command.LifecycleEntry"
                            entrySource
                        )
                let constructors = normalizeHaskellSource constructorSection
                    target = normalizeHaskellSource targetCallback
                    sealer = normalizeHaskellSource sealerSection
                    signature = normalizeHaskellSource producerSignature
                    producer = normalizeHaskellSource producerBody
                    refusal = normalizeHaskellSource refusalSection
                    internal = normalizeHaskellSource internalSource
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
                        , "let reauthorize = ProjectAuthority.authorizeRootProject targetRoot targetVerb targetVerified targetBound targetBinding targetLease targetPlan journal teardownCursor lifecycleContext project reserved <- reauthorize"
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
                        , "withPreparedRootReverseDescentKernel :: forall scope planId rootFrame brokerGeneration verb parentFrame childFrame result. LifecycleEntry scope planId rootFrame brokerGeneration verb -> DescentWork scope planId parentFrame childFrame verb"
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
                    , "project"
                    , "reserved <- reauthorize"
                    , "case reserved of"
                    , "Right authority"
                    , "sealReverseRootEntry"
                    , "reauthorize"
                    ]
                    target
                assertFragmentsInOrder
                    "the producer refuses Up before the two exact root branches"
                    [ "case entry of"
                    , "RootUpLifecycleEntry{} -> refused"
                    , "RootDownLifecycleEntry"
                    , "prepare root verb plan catalog lifecycleContext journal cursor authority reauthorize descent use"
                    , "RootDestroyLifecycleEntry"
                    , "prepare root verb plan catalog lifecycleContext journal cursor authority reauthorize descent use"
                    , "withPreparedReverseDescentKernel"
                    , "acquisitionJournalAdmissionKernel"
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
                sources <- readProductionSources packageRoot
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
                    @?= [ ("HostBootstrap.Teardown.Internal", 3)
                        ]
                importers "HostBootstrap.Teardown.Internal"
                    @?= [ "HostBootstrap.Command.LifecycleEntry"
                        , "HostBootstrap.Handoff.Completion"
                        , "HostBootstrap.Handoff.Process"
                        , "HostBootstrap.Handoff.Relay"
                        ]
                publicExports <- readPublicModuleExports packageRoot
                modulesExporting "withPreparedRootReverseDescentKernel" publicExports @?= []
                modulesExporting "ReverseDescent" publicExports @?= []
                modulesExporting "PreparedReverseDescent" publicExports @?= []
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                metadataPublic <- either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
                metadataHidden <- either assertFailure pure (SourceGuard.mainImplementationHiddenModules cabalSource)
                let exposedModules = metadataPublic
                    otherModules = metadataHidden
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
                    (normalizeHaskellSource entrySource)
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
        , testCase "placement: ordinary lifecycle funnels call the reverse-intent refusal while target acquisition remains available (behaviour: AuthoritySpec)" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                modeSource <- readModuleSource packageRoot "HostBootstrap.Lifecycle.Mode"
                unboundEntry <-
                    requiredSourceSection
                        "ordinary unbound-lease entry"
                        "withUnboundLeaseEntry ::"
                        "type role BoundRunLease nominal nominal nominal nominal"
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
                        "validateBoundRunLeaseAcquisitionJournal ::"
                        modeSource
                profileAdmission <-
                    requiredSourceSection
                        "fresh lifecycle profile admission"
                        "consumeLifecycleProfileSlot ::"
                        "validateLifecycleProfileEvidence ::"
                        modeSource
                refusalBody <-
                    requiredSourceSection
                        "the reverse-intent refusing body and ordinary admission funnel"
                        "refuseReverseRootIntentAt ::"
                        "snapshotKeyForRunKey ::"
                        modeSource
                let refusal = normalizeHaskellSource refusalBody
                assertContains
                    "the refusing body classifies Terminal as clear, a recognized Pending or Committed row as in progress, and anything else as malformed"
                    "Just ReverseRootDownTerminal{} -> Right () Just _ -> Left ModeReverseRootInProgress Nothing -> case decodeReverseRootIntent ProjectDestroy (protectedRecordBytes record) of Just ReverseRootDestroyTerminal{} -> Right () Just _ -> Left ModeReverseRootInProgress Nothing -> Left (ModeMalformedRecord (recordKeyText key))"
                    refusal
                assertContains
                    "the ordinary admission funnel runs the refusal before its action"
                    "withOrdinaryProjectAdmissionForName session project action = do clear <- withModeResult (recoverProductionClosures session) (const (refuseReverseRootIntentForName session project)) case clear of Left failure -> pure (Left failure) Right () -> action"
                    refusal
                let mode = normalizeHaskellSource modeSource
                    unbound = normalizeHaskellSource unboundEntry
                    bound = normalizeHaskellSource boundAdmission
                    fresh = normalizeHaskellSource freshAllocator
                    acquisition = normalizeHaskellSource acquisitionAdmission
                    profile = normalizeHaskellSource profileAdmission
                mapM_
                    (\(label, fragment, source) -> assertContains label fragment source)
                    [
                        ( "unbound snapshot and bind refusal before the supplied action"
                        , "clear <- refuseReverseRootIntentForName session (leaseLocationProjectName location) case clear of Left failure -> pure (Right (Left failure)) Right () -> Right <$> action session"
                        , unbound
                        )
                    ,
                        ( "existing-bound refusal before snapshot preparation"
                        , "clear <- refuseReverseRootIntent session project case clear of Left failure -> pure (Left failure) Right () -> withRecordKey (reverseRootIntentKey project)"
                        , bound
                        )
                    ,
                        ( "retained reverse evidence selects its own kernel while absent mode permits ordinary rearm"
                        , "Right (Just _) -> do mode <- currentMode session project case mode of Left failure -> pure (Left failure) Right Nothing -> prepareExistingBoundSnapshotAt session location project Right (Just _) -> pure (Left ModeReverseRootInProgress)"
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
                        , "clear <- withModeResult (recoverProductionClosures session) (const (refuseReverseRootIntentForName session projectName)) case clear of"
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
                assertContains
                    "ordinary acquisition retains its exact live mode/lease validator"
                    "liveResult <- validateLiveBinding session"
                    acquisition
        , testCase "resource and budget admission stays plan-owned and exactly indexed" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                facadeSource <- readModuleSource packageRoot "HostBootstrap.ProjectPlan"
                budgetSource <-
                    readModuleSource packageRoot "HostBootstrap.Cluster.Budget"
                exportTokens <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan"
                        facadeSource
                let facade = normalizeHaskellSource facadeSource
                    budget = normalizeHaskellSource budgetSource
                budgetAdmissionSignature <- requiredSourceSection
                    "the retained-configuration budget admission signature"
                    "withValidatedBudget ::"
                    "withValidatedBudget plan consume ="
                    budgetSource
                SourceGuard.countHaskellIdentifier "ResourceEnvelope" budgetAdmissionSignature @?= 0
                SourceGuard.countHaskellIdentifier "BudgetCfg" budgetAdmissionSignature @?= 1
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
                        , "withValidatedBudget :: (BudgetCfg cfg) => ProjectPlan scope specDigest planId configId cfg -> (forall budgetId. ValidatedBudget scope planId budgetId -> result) -> Either BudgetError result"
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
                SourceGuard.moduleImportTokens "HostBootstrap.Lifecycle.Plan" budgetSource
                    @?= Just ["projectPlanValidatedConfigKernel"]
                budgetAdmission <- either assertFailure pure $
                    SourceGuard.haskellDefinitionTokens "withValidatedBudget" budgetSource
                assertBool
                    "Budget does not project its envelope from the plan's retained validated configuration"
                    (containsTokenSequence
                        ["budgetResourceEnvelope", "(", "validatedConfigValue", "(", "projectPlanValidatedConfigKernel", "plan", ")", ")"]
                        budgetAdmission)
                publicExports <- readPublicModuleExports packageRoot
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                commandSource <- readModuleSource packageRoot "HostBootstrap.Command"
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
                        "runDown ="
                        command
                teardownCommand <-
                    requiredSourceSection
                        "Production teardown command"
                        "runProductionTeardown root validated ctx cfg verb = do"
                        "openAuthorityStore ::"
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
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                frameSource <-
                    readModuleSource packageRoot "HostBootstrap.ProjectPlan.Frame"
                sessionSource <-
                    readModuleSource packageRoot "HostBootstrap.Lifecycle.Session"
                description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                authorityKernelSource <-
                    SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Authority.Kernel" >>= readFile
                projectAuthoritySource <-
                    readModuleSource packageRoot "HostBootstrap.Authority.ProjectPlan"
                let frame = normalizeHaskellSource frameSource
                    session = normalizeHaskellSource sessionSource
                    authorityKernel = normalizeHaskellSource authorityKernelSource
                    projectAuthority = normalizeHaskellSource projectAuthoritySource
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
                    ]
                SourceGuard.countHaskellIdentifier "authorizeChildProject" projectAuthoritySource @?= 0
        , testCase "child plan admission cannot reopen a root acquisition cursor" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                -- rationale.md: a shared lifecycle-authority mount and generic
                -- protected-store RPC cannot stand in for rooted coordination.
                sources <- readProductionSources packageRoot
                let forbidden = "AuthenticatedChildCursor"
                    occurrences =
                        [ (name, count)
                        | (name, _path, source) <- sources
                        , let count = SourceGuard.countHaskellIdentifier forbidden source
                        , count > 0
                        ]
                SourceGuard.countHaskellIdentifier forbidden ("data " <> forbidden <> " = Forbidden") @?= 1
                occurrences @?= []
        , testCase "reverse children cannot reopen the root acquisition store" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                -- rationale.md: a shared lifecycle-authority mount and generic
                -- protected-store RPC cannot stand in for rooted coordination.
                sources <- readProductionSources packageRoot
                let forbidden = "reopenAuthenticatedRecoveryChildCursorKernel"
                    occurrences =
                        [ (name, count)
                        | (name, _path, source) <- sources
                        , let count = SourceGuard.countHaskellIdentifier forbidden source
                        , count > 0
                        ]
                SourceGuard.countHaskellIdentifier forbidden ("data " <> forbidden <> " = Forbidden") @?= 1
                occurrences @?= []
        , testCase "recovery children cannot acquire root command authority" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                -- rationale.md: a shared lifecycle-authority mount and generic
                -- protected-store RPC cannot stand in for rooted coordination.
                sources <- readProductionSources packageRoot
                let forbidden = "ChildRecoveryOrigin"
                    occurrences =
                        [ (name, count)
                        | (name, _path, source) <- sources
                        , let count = SourceGuard.countHaskellIdentifier forbidden source
                        , count > 0
                        ]
                SourceGuard.countHaskellIdentifier forbidden ("data " <> forbidden <> " = Forbidden") @?= 1
                occurrences @?= []
        , testCase "root lifecycle entries cannot contain a recovery child" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                -- rationale.md: a shared lifecycle-authority mount and generic
                -- protected-store RPC cannot stand in for rooted coordination.
                sources <- readProductionSources packageRoot
                let forbidden = "ChildRecoveryLifecycleEntry"
                    occurrences =
                        [ (name, count)
                        | (name, _path, source) <- sources
                        , let count = SourceGuard.countHaskellIdentifier forbidden source
                        , count > 0
                        ]
                SourceGuard.countHaskellIdentifier forbidden ("data " <> forbidden <> " = Forbidden") @?= 1
                occurrences @?= []
        , testCase "forward children execute only root-selected frame grants" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                -- rationale.md: a shared lifecycle-authority mount and generic
                -- protected-store RPC cannot stand in for rooted coordination.
                sources <- readProductionSources packageRoot
                let forbidden = "AuthorizedChildCursor"
                    occurrences =
                        [ (name, count)
                        | (name, _path, source) <- sources
                        , let count = SourceGuard.countHaskellIdentifier forbidden source
                        , count > 0
                        ]
                SourceGuard.countHaskellIdentifier forbidden ("data " <> forbidden <> " = Forbidden") @?= 1
                occurrences @?= []
        ]

-- Keep every global exposure edge except the exact production imports that
-- Main needs from its private implementation owner.  Removing one occurrence
-- per verified edge leaves any additional component exposure visible below;
-- the independent component and compiler guards check the exact selected test view.
exposedOutsideTrustedImplementation :: String -> IO [String]
exposedOutsideTrustedImplementation description = do
    implementation <-
        maybe (assertFailure "the handoff implementation owner is absent") pure
            (SourceGuard.namedStanza owner description)
    SourceGuard.fieldValues "visibility" implementation @?= ["private"]
    owners <- either assertFailure pure (SourceGuard.mainImplementationOwners description)
    publicModules <- either assertFailure pure (SourceGuard.effectiveMainExposedModules description)
    forM_ trustedMainImports $ \moduleName -> do
        lookup moduleName owners @?= Just owner
        length (filter (== moduleName) (fieldModules "exposed-modules" implementation)) @?= 1
        assertBool
            (moduleName <> " escaped through Main's public facade")
            (moduleName `notElem` publicModules)
    pure (foldl (flip delete) (fieldModules "exposed-modules" description) trustedMainImports)
  where
    owner = "library handoff-implementation-internal"
    trustedMainImports =
        [ "HostBootstrap.Config.Authority.Internal"
        , "HostBootstrap.Config.Install.Native"
        , "HostBootstrap.Config.Schema.Internal"
        , "HostBootstrap.Handoff.Receiver.Internal"
        , "HostBootstrap.Handoff.Recovery"
        , "HostBootstrap.Handoff.Rooted"
        , "HostBootstrap.Handoff.Runtime"
        , "HostBootstrap.Lifecycle.Context.Internal"
        , "HostBootstrap.Lifecycle.Dependency.Internal"
        , "HostBootstrap.Lifecycle.Execution.Internal"
        , "HostBootstrap.Lifecycle.Plan"
        , "HostBootstrap.Lifecycle.Prepared.Internal"
        , "HostBootstrap.Lifecycle.ResourceRecord"
        , "HostBootstrap.Lifecycle.Rooted"
        , "HostBootstrap.Lifecycle.Rooted.Receipt"
        , "HostBootstrap.Lifecycle.RootedPlan"
        , "HostBootstrap.ProjectPlan.Construct.Internal"
        , "HostBootstrap.ProjectPlan.Projection.Internal"
        , "HostBootstrap.Teardown.Internal"
        ]

withPackageSourceRoot :: (FilePath -> FilePath -> IO result) -> IO result
withPackageSourceRoot = SourceGuard.withPackageSourceIn ["src"]

readProductionSources :: FilePath -> IO [(String, FilePath, String)]
readProductionSources packageRoot = do
    description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
    SourceGuard.readLibrarySources packageRoot description

readPublicModuleExports :: FilePath -> IO [(String, [String])]
readPublicModuleExports packageRoot = do
    cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
    exposed <- sort <$> either assertFailure pure (SourceGuard.effectiveMainExposedModules cabalSource)
    sources <- readProductionSources packageRoot
    let sourceByModule =
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

requiredModulePath :: FilePath -> String -> IO FilePath
requiredModulePath packageRoot moduleName = do
    description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
    path <- SourceGuard.libraryModulePath packageRoot description moduleName
    expected <- maybe (assertFailure ("no reviewed physical home for " <> moduleName)) pure $
        lookup moduleName expectedModuleHomes
    SourceGuard.repoRelativePath packageRoot path @?= expected
    pure path

-- Independent physical expectations move only with their named relocation cohort.
expectedModuleHomes :: [(String, FilePath)]
expectedModuleHomes =
    [ ("HostBootstrap.Authority.FailedUp.Internal", "src/HostBootstrap/Authority/FailedUp/Internal.hs")
    , ("HostBootstrap.Authority.ProjectPlan", "src/HostBootstrap/Authority/ProjectPlan.hs")
    , ("HostBootstrap.CLI", "src/HostBootstrap/CLI.hs")
    , ("HostBootstrap.Chain", "src/HostBootstrap/Chain.hs")
    , ("HostBootstrap.Cluster.Budget", "src/HostBootstrap/Cluster/Budget.hs")
    , ("HostBootstrap.Command", "src/HostBootstrap/Command.hs")
    , ("HostBootstrap.Command.Child", "src/HostBootstrap/Command/Child.hs")
    , ("HostBootstrap.Command.LifecycleEntry", "src/HostBootstrap/Command/LifecycleEntry.hs")
    , ("HostBootstrap.Handoff.Process.Route", "src/HostBootstrap/Handoff/Process/Route.hs")
    , ("HostBootstrap.Handoff.Relay", "internal/handoff-implementation/HostBootstrap/Handoff/Relay.hs")
    , ("HostBootstrap.Handoff.Runtime", "internal/handoff-implementation/HostBootstrap/Handoff/Runtime.hs")
    , ("HostBootstrap.Lifecycle.FrameExecutor", "src/HostBootstrap/Lifecycle/FrameExecutor.hs")
    , ("HostBootstrap.Lifecycle.Mode", "internal/handoff-implementation/HostBootstrap/Lifecycle/Mode.hs")
    , ("HostBootstrap.Lifecycle.Plan", "internal/handoff-implementation/HostBootstrap/Lifecycle/Plan.hs")
    , ("HostBootstrap.Lifecycle.Prepared.Internal", "internal/handoff-implementation/HostBootstrap/Lifecycle/Prepared/Internal.hs")
    , ("HostBootstrap.Lifecycle.ReverseRootIntent", "internal/reverse-root-intent/HostBootstrap/Lifecycle/ReverseRootIntent.hs")
    , ("HostBootstrap.Lifecycle.Rooted", "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted.hs")
    , ("HostBootstrap.Lifecycle.Rooted.Node", "src/HostBootstrap/Lifecycle/Rooted/Node.hs")
    , ("HostBootstrap.Lifecycle.Rooted.Receipt", "internal/handoff-implementation/HostBootstrap/Lifecycle/Rooted/Receipt.hs")
    , ("HostBootstrap.Lifecycle.RootedPlan", "internal/handoff-implementation/HostBootstrap/Lifecycle/RootedPlan.hs")
    , ("HostBootstrap.Lifecycle.Session", "internal/handoff-implementation/HostBootstrap/Lifecycle/Session.hs")
    , ("HostBootstrap.Lifecycle.Session.Testing", "src/HostBootstrap/Lifecycle/Session/Testing.hs")
    , ("HostBootstrap.ProjectPlan", "internal/handoff-implementation/HostBootstrap/ProjectPlan.hs")
    , ("HostBootstrap.ProjectPlan.Construct", "src/HostBootstrap/ProjectPlan/Construct.hs")
    , ("HostBootstrap.ProjectPlan.Construct.Internal", "internal/handoff-implementation/HostBootstrap/ProjectPlan/Construct/Internal.hs")
    , ("HostBootstrap.ProjectPlan.Frame", "internal/handoff-implementation/HostBootstrap/ProjectPlan/Frame.hs")
    , ("HostBootstrap.ProjectPlan.Handoff.Internal", "src/HostBootstrap/ProjectPlan/Handoff/Internal.hs")
    , ("HostBootstrap.ProjectPlan.Projection.Internal", "internal/handoff-implementation/HostBootstrap/ProjectPlan/Projection/Internal.hs")
    , ("HostBootstrap.ProjectPlan.Snapshot", "src/HostBootstrap/ProjectPlan/Snapshot.hs")
    , ("HostBootstrap.Step", "internal/handoff-implementation/HostBootstrap/Step.hs")
    , ("HostBootstrap.Teardown", "internal/handoff-implementation/HostBootstrap/Teardown.hs")
    , ("HostBootstrap.Teardown.Internal", "internal/handoff-implementation/HostBootstrap/Teardown/Internal.hs")
    ]

readModuleSource :: FilePath -> String -> IO String
readModuleSource packageRoot moduleName = requiredModulePath packageRoot moduleName >>= readFile

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

definitionUsesIdentifier :: String -> String -> IO Bool
definitionUsesIdentifier wanted source = do
    names <- either assertFailure pure (SourceGuard.haskellDefinitionNames source)
    clauses <- traverse definitionClauses [name | name@(first : _) <- names, isLower first || first == '_']
    pure (any (elem wanted) (concat clauses))
  where
    definitionClauses name = case SourceGuard.haskellDefinitionClauseTokens name source of
        Right tokens -> pure tokens
        -- Record selectors and class method signatures are named declarations
        -- without a top-level value body. They cannot call the runner.
        Left missing | missing == "value definition missing: " <> name -> pure []
        Left failure -> assertFailure failure

requiredSourceSection :: String -> String -> String -> String -> IO String
requiredSourceSection = requiredSourceSectionWith False

-- Include a genuine opening declaration when the retained scope owns its
-- signature or data header, as well as the body that follows it.
requiredSourceSectionFrom :: String -> String -> String -> String -> IO String
requiredSourceSectionFrom = requiredSourceSectionWith True

requiredSourceSectionWith :: Bool -> String -> String -> String -> String -> IO String
requiredSourceSectionWith includeOpening label opening closing source =
    case sourceSection includeOpening opening closing source of
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

sourceSection :: Bool -> String -> String -> String -> Maybe String
sourceSection includeOpening opening closing source
    | null (normalizeHaskellSource opening) || null (normalizeHaskellSource closing) = Nothing
    | otherwise = do
        afterOpening <- dropThrough opening (SourceGuard.stripHaskellComments source)
        section <- takeBefore closing afterOpening
        pure (if includeOpening then opening <> section else section)

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
        (containsSourceFragment expected source)

normalizeHaskellSource :: String -> String
normalizeHaskellSource = SourceGuard.normalizeWhitespace . SourceGuard.stripHaskellComments

containsSourceFragment :: String -> String -> Bool
containsSourceFragment expected source =
    normalizeHaskellSource expected `isInfixOf` normalizeHaskellSource source

assertAbsent :: String -> String -> String -> IO ()
assertAbsent label forbidden source =
    assertBool
        (label <> ": " <> show forbidden)
        (not (forbidden `isInfixOf` source))

assertFragmentsInOrder :: String -> [String] -> String -> IO ()
assertFragmentsInOrder label fragments source =
    assertBool
        (label <> " is missing or misorders source shapes: " <> show fragments)
        (sourceFragmentsInOrder fragments source)

sourceFragmentsInOrder :: [String] -> String -> Bool
sourceFragmentsInOrder fragments source = go (normalizeHaskellSource source) (map normalizeHaskellSource fragments)
  where
    go _ [] = True
    go remainingSource (fragment : remaining) =
        case dropThrough fragment remainingSource of
            Nothing -> False
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

assertRecoveryMismatchExact :: Text.Text -> Text.Text -> Text.Text -> Either PlanError () -> IO ()
assertRecoveryMismatchExact subject expected observed outcome =
    outcome @?= Left (PlanRecoveryEvidenceMismatch subject expected observed)

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
    LifecycleProfile scope ->
    FinalizedProjectSpec scope specDigest Fixture.ProjectConfig ->
    FilePath ->
    Fixture.ProjectConfig scope ->
    IO (Text.Text, [(StepIdentity, Text.Text)])
exerciseFinalizedSpec profile spec directory value = do
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
                            drafts <- expectRight (projectPlanDrafts spec root validated)
                            steps <-
                                expectRight $
                                    withProjectPlan profile root validated drafts $ \plan ->
                                        [ (plannedStepIdentity node, plannedStepLabel node)
                                        | node <- NonEmpty.toList (forward plan)
                                        ]
                            finalizedServiceVariantNames
                                (finalizedProjectServices spec)
                                @?= ["probe"]
                            pure (expectedDigest, steps)
                        )
                either fail pure admitted
            )
    either (fail . show) pure rooted

fixtureServiceRegistry :: ServiceRegistry Fixture.ProjectConfig
fixtureServiceRegistry = metadataServiceRegistry "probe"

alternateFixtureServiceRegistry :: ServiceRegistry Fixture.ProjectConfig
alternateFixtureServiceRegistry = metadataServiceRegistry "alternate-probe"

-- These registries exercise finalization identity with an empty effect row.
-- Any backend dispatch would violate the fixture's declared purpose.
metadataServiceRegistry :: String -> ServiceRegistry Fixture.ProjectConfig
metadataServiceRegistry name =
    singletonServiceRegistry
        ( serviceProgramDefinition
            (either (error . show) id (serviceId name))
            (\_ -> Right (Just ()))
            NoEffects
            resources
            (backend :: ServiceBackend ())
            (const (pure ()))
        )
  where
    resources =
        ServiceResourceBackend
            { serviceRolePlanDraft = either (error . show) id $ do
                request <- mkRoleResourceRequest "metadata" False
                rolePlanDraft [request]
            , servicePrerequisite = pure PrereqSatisfied
            , serviceAcquireResource = \_ -> pure Acquired
            , serviceProbeResource = \_ -> pure ProbeReadyNow
            , serviceReleaseResource = \_ -> pure Released
            }
    backend =
        ServiceBackend
            { backendServe = \_ -> fail "NoEffects fixture dispatched listen"
            , backendCall = \_ _ -> fail "NoEffects fixture dispatched call"
            , backendWork = \_ _ -> fail "NoEffects fixture dispatched work"
            }

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
            (fixtureSnapshotKey project runName)
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

fixtureSnapshotKey :: InstalledProjectIdentity projectId -> Text.Text -> Either ProtectedError RecordKey
fixtureSnapshotKey project runName = do
    encodedProject <- mkRecordName (installedProjectName project)
    encodedRun <- mkRecordName runName
    mkRecordKey ("snapshot." <> encodedProject <> recordTupleSeparator <> encodedRun)

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

jointFinalizationPlan :: StepPlan
jointFinalizationPlan =
    expectStepPlan
        [ contextInitStep "first root step" frame (const (pure StepChanged))
        , ensureStep "ghc" "second tool step" frame (const (pure StepChanged))
        ]
  where
    frame = StepFrame "host" "Host"

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
            (either error id (projectStepId "deploy-object-store"))
            PreserveOnReverse
            "object store"
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

-- Keep both resources valid while the share has no earlier provider dependency.
-- The later cluster admits both resources, in the opposite order to the alias.
shareBeforeProviderResourcePlan :: StepPlan
shareBeforeProviderResourcePlan =
    expectStepPlan
        [ copySourceStep "durable share" frame (const (pure StepChanged))
        , deployVMStep "provider" frame (const (pure StepChanged))
        , deployKindStep "cluster" frame (const (pure StepChanged))
        ]
  where
    frame = StepFrame "host" "Host"

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
    case NonEmpty.toList (stepPlanSteps (chartWorkloadPlanAt "shared-service-frame" "sha256:workload")) of
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

framedLabelPlan :: String -> String -> StepPlan
framedLabelPlan fid label =
    expectStepPlan
        [ contextInitStep
            "same step label"
            (StepFrame fid label)
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

framedText :: Text.Text -> ByteString.ByteString
framedText = LazyByteString.toStrict . Builder.toLazyByteString . encodeSnapshotText

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
        [ "484f5354424f4f5453545241502d504c414e0000000000000008"
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

joinPlan :: Either PlanError (Either PlanError value) -> Either PlanError value
joinPlan = either Left id

expectPlanAccepted :: Either PlanError () -> IO ()
expectPlanAccepted = either (assertFailure . show) pure
