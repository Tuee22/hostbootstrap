{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module CLISpec (runSchemaFixture, tests) where

import Control.Exception (finally, throwIO, try)
import Control.Monad (filterM)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TIO
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.CLI (
    ProjectSpec,
    ProjectSpecBuilder,
    ProjectSpecError (..),
    addForwardChildPlan,
    addArtifacts,
    addAssemblyInputs,
    addServices,
    addSteps,
    finalizeProjectSpec,
    projectArtifactNames,
    projectServiceVariantNames,
    projectSpec,
    projectStepPlan,
 )
import qualified HostBootstrap.CLI as CLI
import HostBootstrap.Command (coreCommandNames)
import HostBootstrap.Config.Class (AssemblyRequest (..), ConfigAssembly, ProjectCfg (withProductionProjectCodec), configInput, pureConfigAssembly)
import HostBootstrap.Config.Fields (ScopeKind (ProductionScope))
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Context (ContextKind (HostOrchestrator))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (ConfigArtifact, artifactOf, autoCodecWitness, requireCodecWitness)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Authority (
    InstalledProjectIdentity,
    authorityErrorMessage,
    installedProjectName,
    normalizeExecutableIdentity,
    withInstalledProjectIdentity,
 )
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Harness (
    Case (Case),
    CaseId,
    allCasesSelector,
    CaseResult (Fail, Pass),
    SafetyRefusal (SafetyRefusal),
    TestSuite (TestSuite),
    mkCaseId,
 )
import HostBootstrap.Lifecycle.Execution (stepExecutionPlanDigest)
import HostBootstrap.Lifecycle.Mode (
    ProductionRoot,
    inspectPlanSnapshot,
    modeErrorMessage,
    planSnapshotViewPlanDigest,
    planSnapshotViewRevision,
    planSnapshotViewSpecDigest,
    productionActiveMode,
    productionRootAuthority,
    productionRootModeLease,
    productionRootUnboundLease,
    withAcquisitionJournal,
    withExecuteLifecycleCursor,
    withLifecycleCursor,
    withProductionLifecycleProfile,
    withProductionRoot,
 )
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    renderSnapshot,
    stablePlanSnapshotBytes,
    stablePlanSnapshotConfigDigest,
    stablePlanSnapshotDigest,
    stablePlanSnapshotRoot,
    stablePlanSnapshotSpecDigest,
 )
import HostBootstrap.ProjectPlan.Construct (
    finalizedProjectCodec,
    projectPlanDrafts,
    withFinalizedProjectSpec,
    withProjectPlan,
 )
import HostBootstrap.ProjectPlan.Frame (withCurrentFrame)
import HostBootstrap.ProjectPlan.Snapshot (withPersistedPlanSnapshot)
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    compareAndDeleteProtectedRecord,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
    readProtectedRecord,
    recordKeyText,
    recordVersionWord,
    tryProtectedEntry,
    withProtectedEntry,
 )
import HostBootstrap.RoleLifecycle (
    DeclaredEffects (NoEffects, WithEffect),
    EffectName (NetworkListenName),
 )
import HostBootstrap.Service (
    ServiceRegistry,
    ServiceRegistryError (..),
    emptyServiceRegistry,
    serviceDefinition,
    serviceId,
    serviceRegistry,
    serviceRoleSchemaFamilies,
    withFinalizedServiceRegistry,
 )
import HostBootstrap.Lift.Context (IncusVM (IncusVM), inVM, localContext)
import HostBootstrap.Step (ProjectStepId, ReversePolicy (PreserveOnReverse, ProjectManagedReverse), Step, StepFrame (..), StepObservation (..), StepPlanError (DuplicateStepIdentities), TeardownAction (DeleteFrame, StopFrame), TeardownOutcome (TeardownReleased), deployVMStep, descendsVia, projectStep, projectStepId, reversedBy, stepLabel, stepPlanSteps)
import System.Directory (doesDirectoryExist, doesFileExist, doesPathExist, getCurrentDirectory, listDirectory, removeFile)
import System.Environment (getExecutablePath, lookupEnv, setEnv, unsetEnv, withArgs)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), die)
import System.FilePath (makeRelative, takeExtension, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

{- | The fixture-backed project spec the CLI tests drive (generic over the
core-internal 'Fixture.ProjectConfig' + 'Fixture.TestConfig'). The init builders
are the fixture's, so @project init@ / @test init@ / @test run@ exercise the
real generic command machinery against a concrete config.
-}
builderWith ::
    TestSuite ->
    IO () ->
    [ConfigArtifact] ->
    ProjectSpecBuilder Fixture.ProjectConfig Fixture.TestConfig
builderWith = builderWithHarnessContext "/workspace/demo" "cli"

-- | A CLI fixture whose restricted Harness assembler retains the exact
-- canonical root selected by the surrounding runtime test.
builderWithHarnessContext ::
    FilePath ->
    T.Text ->
    TestSuite ->
    IO () ->
    [ConfigArtifact] ->
    ProjectSpecBuilder Fixture.ProjectConfig Fixture.TestConfig
builderWithHarnessContext root projectName suite check arts =
    addForwardChildPlan Fixture.refusingForwardChildPlan $
        builderWithoutForwardChildPlan root projectName suite check arts

builderWithoutForwardChildPlan ::
    FilePath ->
    T.Text ->
    TestSuite ->
    IO () ->
    [ConfigArtifact] ->
    ProjectSpecBuilder Fixture.ProjectConfig Fixture.TestConfig
builderWithoutForwardChildPlan root projectName suite check arts =
    projectSpec
        suite
        check
        arts
        Fixture.testConfigCodec
        fixtureTestInit
        (fixtureAssembleAt root projectName)

{- | A CLI fixture whose forward-child projector really projects one VM
descent, so the recursive catalog admits a descent entry instead of refusing at
the first declared edge.
-}
builderWithProjectingChild ::
    FilePath ->
    [Step] ->
    TestSuite ->
    IO () ->
    [ConfigArtifact] ->
    ProjectSpecBuilder Fixture.ProjectConfig Fixture.TestConfig
builderWithProjectingChild descriptor steps suite check arts =
    addForwardChildPlan (Fixture.projectingForwardChildPlan descriptor steps) $
        builderWithoutForwardChildPlan "/workspace/demo" "cli" suite check arts

specWith ::
    TestSuite ->
    IO () ->
    [ConfigArtifact] ->
    ProjectSpec Fixture.ProjectConfig Fixture.TestConfig
specWith suite check arts =
    finalized (addSteps sampleChain (builderWith suite check arts))

specWithHarnessContext ::
    FilePath ->
    T.Text ->
    TestSuite ->
    IO () ->
    [ConfigArtifact] ->
    ProjectSpec Fixture.ProjectConfig Fixture.TestConfig
specWithHarnessContext root projectName suite check arts =
    finalized
        (addSteps sampleChain (builderWithHarnessContext root projectName suite check arts))

finalized ::
    ProjectSpecBuilder Fixture.ProjectConfig Fixture.TestConfig ->
    ProjectSpec Fixture.ProjectConfig Fixture.TestConfig
finalized = either (error . show) id . finalizeProjectSpec

fixtureTestInit :: a -> Fixture.TestConfig
fixtureTestInit _ = Fixture.defaultTestConfig (Fixture.Resources 4 "8GiB" "20GiB")

fixtureAssembleAt ::
    FilePath ->
    T.Text ->
    forall projectId scope.
    AssemblyRequest projectId Fixture.TestConfig T.Text scope ->
    ConfigAssembly scope (Fixture.ProjectConfig scope)
fixtureAssembleAt root projectName request =
    case request of
        ProductionAssembly args ->
            pureConfigAssembly (Fixture.projectInit "cli" args)
        HarnessAssembly _ _ _ ->
            pureConfigAssembly
                (Fixture.defaultProjectConfig projectName (T.pack root) HostOrchestrator)

runHostBootstrapCLI ::
    ProjectSpec Fixture.ProjectConfig Fixture.TestConfig ->
    IO ()
runHostBootstrapCLI spec = do
    projectName <- executableProjectName
    CLI.runHostBootstrapCLI (T.unpack projectName) spec

executableProjectName :: IO T.Text
executableProjectName = normalizeExecutableIdentity <$> getExecutablePath

tests :: TestTree
tests =
    testGroup
        "CLISpec"
        [ testCase "project specs reject an empty test suite before dispatch" $
            case finalizeProjectSpec
                (addSteps sampleChain (builderWith emptySuiteFixture (pure ()) [])) of
                Left EmptyProjectTestSuite -> pure ()
                other -> assertFailure ("expected EmptyProjectTestSuite, got " ++ either show (const "Right ProjectSpec") other)
        , testCase "real project specs reject a missing forward-child projector" $
            case
                finalizeProjectSpec
                    ( addSteps sampleChain $
                        builderWithoutForwardChildPlan
                            "/workspace/demo"
                            "cli"
                            passingSuite
                            (pure ())
                            []
                    )
            of
                Left MissingForwardChildPlan -> pure ()
                other -> assertFailure ("expected MissingForwardChildPlan, got " ++ either show (const "Right ProjectSpec") other)
        , testCase "one forward-child projector completes real project finalization" $
            case
                finalizeProjectSpec
                    (addSteps sampleChain (builderWith passingSuite (pure ()) []))
            of
                Right _ -> pure ()
                Left failure -> assertFailure ("expected one projector to finalize, got " ++ show failure)
        , testCase "duplicate forward-child projectors refuse instead of replacing" $
            case
                finalizeProjectSpec
                    ( addSteps sampleChain $
                        addForwardChildPlan
                            Fixture.refusingForwardChildPlan
                            (builderWith passingSuite (pure ()) [])
                    )
            of
                Left DuplicateForwardChildPlan -> pure ()
                other -> assertFailure ("expected DuplicateForwardChildPlan, got " ++ either show (const "Right ProjectSpec") other)
        , testCase "runtime executable identity must match the declared project" $ do
            actualProject <- executableProjectName
            result <-
                try
                    ( CLI.runHostBootstrapCLI
                        (T.unpack (actualProject <> "-declared-mismatch"))
                        (specWith passingSuite (pure ()) [])
                    ) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "core command surface has five user-facing verbs and no ensure command" $
            coreCommandNames @?= ["context", "project", "test", "service", "check-code"]
        , testCase "project specs reject duplicate service variants across additive fragments" $ do
            let web = fixtureServiceRegistry Nothing [("web", pure ())]
                builder =
                    addServices web $
                        addServices web $
                            addSteps sampleChain $
                                builderWith passingSuite (pure ()) []
            case finalizeProjectSpec builder of
                Left (InvalidServiceRegistry (DuplicateServiceIds _)) -> pure ()
                other -> assertFailure ("expected duplicate service rejection, got " ++ either show (const "Right ProjectSpec") other)
        , testCase "service registries compose additively across layers" $ do
            let layered =
                    finalized $
                        addServices
                            (fixtureServiceRegistry Nothing [("accelerator", pure ())])
                            ( addServices
                                (fixtureServiceRegistry Nothing [("web", pure ())])
                                ( addSteps sampleChain $
                                    builderWith passingSuite (pure ()) []
                                )
                            )
            projectServiceVariantNames layered @?= ["web", "accelerator"]
        , testCase "an empty registry has structured Production and Harness schema families" $ do
            let schemas =
                    withProductionProjectCodec @Fixture.ProjectConfig @Fixture.FixtureProject $ \baseCodec ->
                        withFinalizedServiceRegistry
                            ProductionScope
                            baseCodec
                            emptyServiceRegistry
                            (\_ registry -> serviceRoleSchemaFamilies registry)
            assertBool "Production empty family is explicit" ("service schema family Production:\n  services = []\n  schemas = []" `T.isInfixOf` schemas)
            assertBool "Harness empty family is explicit" ("service schema family Harness:\n  services = []\n  schemas = []" `T.isInfixOf` schemas)
        , -- There is no lifecycle slot left beside the plan: a spec with no steps
          -- is the only remaining structural gap, and the reverse effect lives on
          -- the step that acquires the resource.
          testCase "a spec with no step contribution cannot be finalized" $
            case finalizeProjectSpec (builderWith passingSuite (pure ()) []) of
                Left MissingStepPlan -> pure ()
                other -> assertFailure ("expected MissingStepPlan, got " ++ either show (const "Right ProjectSpec") other)
        , testCase "independent step fragments append in exact declaration order" $ do
            let first :: FixtureFragment
                first _ _ =
                    [projectStep (fixtureProjectStepId "first-fragment") ProjectManagedReverse "first" (StepFrame "host-orchestrator-0" "host") (const (pure StepChanged))]
                second :: FixtureFragment
                second _ _ =
                    [projectStep (fixtureProjectStepId "second-fragment") ProjectManagedReverse "second" (StepFrame "host-orchestrator-0" "host") (const (pure StepChanged))]
                spec =
                    finalized $
                        addSteps second $
                            addSteps first $
                                builderWith passingSuite (pure ()) []
                cfg = Fixture.defaultProjectConfig "cli-fragments" "." HostOrchestrator
            plan <-
                Fixture.withFixtureProjectRoot $ \root ->
                    either (assertFailure . show) pure (projectStepPlan spec root cfg)
            map stepLabel (stepPlanSteps plan) @?= ["first", "second"]
        , testCase "the finalized step planner accepts the exact Harness config scope" $ do
            let spec = finalized (addSteps sampleChain (builderWith passingSuite (pure ()) []))
                harnessCfg :: Fixture.ProjectConfig (V.Harness Fixture.FixtureProject HarnessPlanRun)
                harnessCfg = Fixture.defaultProjectConfig "cli-harness-plan" "." HostOrchestrator
            plan <- withSystemTempDirectory "hostbootstrap-cli-harness-plan" $ \directory -> do
                rooted <-
                    withCanonicalProjectRoot
                        (directory </> "fixture.dhall")
                        "."
                        ( \root ->
                            either
                                (assertFailure . show)
                                pure
                                (projectStepPlan spec root harnessCfg)
                        )
                either (assertFailure . show) pure rooted
            map stepLabel (stepPlanSteps plan) @?= ["launch the VM"]
        , testCase "artifact fragments compose associatively without erasure" $ do
            let budgetCodec = requireCodecWitness "CLISpec.Budget" (autoCodecWitness @V.Budget)
                firstArtifact = artifactOf "fragmentA" budgetCodec (V.Budget 1 2 3)
                secondArtifact = artifactOf "fragmentB" budgetCodec (V.Budget 2 3 4)
                finish builder =
                    finalized $
                        addSteps sampleChain $
                            builder
                separately =
                    finish $
                        addArtifacts [secondArtifact] $
                            addArtifacts [firstArtifact] $
                                builderWith passingSuite (pure ()) []
                together =
                    finish $
                        addArtifacts [firstArtifact, secondArtifact] $
                            builderWith passingSuite (pure ()) []
            projectArtifactNames separately @?= ["fragmentA", "fragmentB"]
            projectArtifactNames separately @?= projectArtifactNames together
        , testCase "duplicate assembly inputs return a structured construction error" $ do
            let input = configInput "settings.dhall"
                builder =
                    addAssemblyInputs [input] $
                        addAssemblyInputs [input] $
                            addSteps sampleChain $
                                builderWith passingSuite (pure ()) []
            case finalizeProjectSpec builder of
                Left (DuplicateAssemblyInputs ["settings.dhall"]) -> pure ()
                other -> assertFailure ("expected duplicate assembly-input rejection, got " ++ either show (const "validated") other)
        , testCase "duplicate identities across additive fragments fail before interpretation" $ do
            let duplicate :: FixtureFragment
                duplicate _ _ =
                    [projectStep (fixtureProjectStepId "shared") ProjectManagedReverse "duplicate" (StepFrame "host-orchestrator-0" "host") (const (pure StepChanged))]
                spec =
                    finalized $
                        addSteps duplicate $
                            addSteps duplicate $
                                addArtifacts [] (builderWith passingSuite (pure ()) [])
                cfg = Fixture.defaultProjectConfig "cli-duplicates" "." HostOrchestrator
            outcome <- Fixture.withFixtureProjectRoot (\root -> pure (projectStepPlan spec root cfg))
            case outcome of
                Left (DuplicateStepIdentities _) -> pure ()
                other -> assertFailure ("expected duplicate step rejection, got " ++ either show (const "validated") other)
        , testCase "check-code runs the project-supplied hook" $ do
            ran <- newIORef False
            withProjectConfig $ do
                result <-
                    try (withArgs ["check-code"] (runHostBootstrapCLI (specWith passingSuite (writeIORef ran True) []))) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef ran >>= (@?= True)
        , testCase "check-code exits non-zero when the hook fails" $
            withProjectConfig $ do
                result <-
                    try (withArgs ["check-code"] (runHostBootstrapCLI (specWith passingSuite (die "seeded check failure") []))) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "test run fails fast without a test.dhall" $
            withProjectConfig $ do
                result <-
                    try (withArgs ["test", "run", "all"] (runHostBootstrapCLI (specWith passingSuite (pure ()) []))) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "test init writes a test config without a pre-existing project config" $ do
            projectName <- executableProjectName
            testPath <- Schema.siblingTestConfigPath projectName
            ( do
                    result <-
                        try (withArgs ["test", "init"] (runHostBootstrapCLI (specWith passingSuite (pure ()) []))) ::
                            IO (Either ExitCode ())
                    result @?= Right ()
                )
                `finally` removeFile testPath
        , testCase "test init refuses an existing test config unless replacement is requested" $ do
            projectName <- executableProjectName
            testPath <- Schema.siblingTestConfigPath projectName
            let spec = specWith passingSuite (pure ()) []
                initWith args =
                    try (withArgs ("test" : "init" : args) (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
            ( do
                    first <- initWith []
                    first @?= Right ()
                    original <- TIO.readFile testPath
                    -- A second plain `init` must not silently replace what the
                    -- operator may have edited.
                    refused <- initWith []
                    refused @?= Left (ExitFailure 1)
                    TIO.writeFile testPath (original <> "-- operator edit\n")
                    edited <- TIO.readFile testPath
                    stillThere <- initWith []
                    stillThere @?= Left (ExitFailure 1)
                    TIO.readFile testPath >>= (@?= edited)
                    -- Explicit replacement is the only route that overwrites.
                    replaced <- initWith ["--replace"]
                    replaced @?= Right ()
                    TIO.readFile testPath >>= (@?= original)
                )
                `finally` removeFile testPath
        , testCase "test init then test run exits non-zero when a case fails (config is generated then removed)" $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            stateRoot <- getCurrentDirectory
            let spec =
                    specWithHarnessContext
                        stateRoot
                        projectName
                        failingSuite
                        (pure ())
                        []
            ( do
                    _ <-
                        try (withArgs ["test", "init"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                    result <-
                        try (withArgs ["test", "run", "all"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                    result @?= Left (ExitFailure 1)
                    doesFileExist cfgPath >>= (@?= False)
                    -- No sidecar of any shape survives: ownership is the
                    -- protected record the run settles, not a lock directory
                    -- beside the config (the test-harness-and-run-ownership phase).
                    doesPathExist (cfgPath ++ ".hostbootstrap-test-owner") >>= (@?= False)
                )
                `finally` removeFile testPath
        , testCase "test run interprets one exact Harness plan through forward and reverse" $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            stateRoot <- getCurrentDirectory
            let storeRoot =
                    stateRoot
                        </> ".hostbootstrap"
                        </> "authority"
                        </> T.unpack projectName
            observed <- newIORef []
            events <- newIORef ([] :: [String])
            forwardPlanDigests <- newIORef []
            postReverseConfigPresence <- newIORef []
            let frame = StepFrame "host-orchestrator-0" "metal"
                exactHarnessChain :: FixtureFragment
                exactHarnessChain _ _ =
                    [ reversedBy
                        ( \_ _ -> do
                            modifyIORef' events (++ ["reverse"])
                            pure TeardownReleased
                        )
                        ( projectStep
                            (fixtureProjectStepId "exact-harness-probe")
                            ProjectManagedReverse
                            "record exact Harness interpretation"
                            frame
                            ( \execution -> do
                                modifyIORef' events (++ ["forward"])
                                modifyIORef' forwardPlanDigests (++ [stepExecutionPlanDigest execution])
                                pure StepChanged
                            )
                        )
                    ]
                suite =
                    TestSuite
                        (pure (Right ()))
                        ( \_ -> do
                            generatedConfigPresent <- doesFileExist cfgPath
                            records <- observeBoundHarnessPlan storeRoot projectName
                            modifyIORef' observed (++ [(generatedConfigPresent, records)])
                            pure ()
                        )
                        [Case (fixtureCaseId "ok") 1 False]
                        (\_ _ -> pure Pass)
                        ( do
                            generatedConfigPresent <- doesFileExist cfgPath
                            modifyIORef' postReverseConfigPresence (++ [generatedConfigPresent])
                        )
                spec =
                    finalized $
                        addSteps
                            exactHarnessChain
                            (builderWithHarnessContext stateRoot projectName suite (pure ()) [])
            ( do
                    initialized <-
                        try (withArgs ["test", "init"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                    initialized @?= Right ()
                    ran <-
                        try (withArgs ["test", "run", "all"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                    ran @?= Right ()
                    observations <- readIORef observed
                    length observations @?= 2
                    exact <-
                        mapM
                            ( \case
                                (True, Right result) -> pure result
                                other ->
                                    assertFailure
                                        ("the live body did not observe a generated config plus exact Harness records: " ++ show other)
                            )
                            observations
                    mapM_
                        ( \(runName, specDigest, planDigest, image) -> do
                            assertBool
                                "the bound lease uses the acquired generative run"
                                ("run-" `T.isPrefixOf` runName)
                            assertBool "the snapshot carries a spec digest" (not (T.null specDigest))
                            assertBool
                                "the exact plan digest is derived from the spec and step plan"
                                (specDigest `T.isPrefixOf` planDigest)
                            let acquisition =
                                    recordsWithPrefix
                                        ("acquisition." <> projectName <> "." <> runName <> ".")
                                        image
                                invocation =
                                    recordsWithPrefix "invocation." image
                                cursors =
                                    filter
                                        (recordImageContains runName)
                                        (recordsWithPrefix "cursor." image)
                            length acquisition @?= 1
                            length cursors @?= 1
                            assertBool
                                "the acquisition journal retains the exact Harness run"
                                (all (recordImageContains runName) acquisition)
                            assertBool
                                "the lifecycle cursor retains its exact run through the acquisition source"
                                (all (recordImageContains runName) cursors)
                            brokerEpoch <-
                                case acquisition of
                                    [record] ->
                                        case drop 10 (recordImageFields record) of
                                            epoch : _ -> pure epoch
                                            _ -> assertFailure "the acquisition journal omitted its broker epoch"
                                    _ -> assertFailure "the exact acquisition journal was not unique"
                            let framed value =
                                    T.pack
                                        ( show
                                            ( ByteString.length
                                                (TextEncoding.encodeUtf8 value)
                                            )
                                        )
                                        <> ":"
                                        <> value
                                exactInvocations =
                                    filter
                                        ( \record ->
                                            recordImageContains (framed planDigest) record
                                                && recordImageContains (framed brokerEpoch) record
                                                && recordImageContains (framed "host-orchestrator-0") record
                                        )
                                        invocation
                            length exactInvocations @?= 1
                            assertBool
                                "the command invocation retains the exact Harness plan"
                                (all (recordImageContains (framed planDigest)) exactInvocations)
                            assertBool
                                "the command invocation retains the installed project authority"
                                (all (recordImageContains (framed projectName)) exactInvocations)
                        )
                        exact
                    digests <- readIORef forwardPlanDigests
                    digests @?= map (\(_, _, planDigest, _) -> planDigest) exact
                    readIORef events >>= (@?= ["forward", "reverse", "forward", "reverse"])
                    readIORef postReverseConfigPresence >>= (@?= [True, True])
                    doesFileExist cfgPath >>= (@?= False)
                )
                `finally` removeFile testPath
        , testCase "a true pre-effect Harness refusal skips reverse and admits the successor variant" $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            stateRoot <- getCurrentDirectory
            forwardCalls <- newIORef (0 :: Int)
            reverseCalls <- newIORef (0 :: Int)
            let refusalChain :: FixtureFragment
                refusalChain _ _ =
                    [ reversedBy
                        (\_ _ -> modifyIORef' reverseCalls (+ 1) >> pure TeardownReleased)
                        ( projectStep
                            (fixtureProjectStepId "harness-pre-effect-refusal")
                            ProjectManagedReverse
                            "refuse before acquisition"
                            (StepFrame "host-orchestrator-0" "metal")
                            ( \_ -> do
                                modifyIORef' forwardCalls (+ 1)
                                throwIO (SafetyRefusal "pre-existing operator state")
                            )
                        )
                    ]
                spec =
                    finalized
                        ( addSteps
                            refusalChain
                            ( builderWithHarnessContext
                                stateRoot
                                projectName
                                passingSuite
                                (pure ())
                                []
                            )
                        )
            ( do
                    initialized <-
                        try (withArgs ["test", "init"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                    initialized @?= Right ()
                    ran <-
                        try (withArgs ["test", "run", "all"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                    ran @?= Left (ExitFailure 1)
                    -- Both fixture variants reaching the forward action proves
                    -- the first BoundFallback close released its exact Harness
                    -- mode before the successor variant was admitted.
                    readIORef forwardCalls >>= (@?= 2)
                    readIORef reverseCalls >>= (@?= 0)
                    doesFileExist cfgPath >>= (@?= False)
                )
                `finally` removeFile testPath
        , testCase "a late Harness refusal reverses each acquired variant exactly once" $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            stateRoot <- getCurrentDirectory
            let storeRoot =
                    stateRoot
                        </> ".hostbootstrap"
                        </> "authority"
                        </> T.unpack projectName
            acquired <- newIORef (0 :: Int)
            refused <- newIORef (0 :: Int)
            reversed <- newIORef (0 :: Int)
            postReverseChecks <- newIORef (0 :: Int)
            effectRecords <- newIORef []
            let recordAcquisition = do
                    observed <- observeBoundHarnessPlan storeRoot projectName
                    (runName, _, _, _) <- either assertFailure pure observed
                    key <-
                        either (assertFailure . show) pure $
                            mkRecordKey
                                ( "effect."
                                    <> projectName
                                    <> "."
                                    <> runName
                                    <> ".late-refusal"
                                )
                    store <-
                        openProtectedStore storeRoot
                            >>= either (assertFailure . T.unpack . protectedErrorMessage) pure
                    version <-
                        withProtectedEntry store
                            (\session -> compareAndSwapProtectedRecord session key ExpectAbsent "acquired")
                            >>= either (assertFailure . T.unpack . protectedErrorMessage) pure
                    modifyIORef' effectRecords (++ [(key, version)])
                    modifyIORef' acquired (+ 1)
                    pure StepChanged
                releaseAcquisition _ _ = do
                    records <- readIORef effectRecords
                    (key, version) <- case records of
                        [] -> assertFailure "reverse ran without the acquired effect record"
                        current : rest -> writeIORef effectRecords rest >> pure current
                    store <-
                        openProtectedStore storeRoot
                            >>= either (assertFailure . T.unpack . protectedErrorMessage) pure
                    deleted <-
                        withProtectedEntry store $ \session ->
                            compareAndDeleteProtectedRecord session key (ExpectVersion version)
                    either (assertFailure . T.unpack . protectedErrorMessage) pure deleted
                    modifyIORef' reversed (+ 1)
                    pure TeardownReleased
                lateRefusalChain :: FixtureFragment
                lateRefusalChain _ _ =
                    [ reversedBy
                        releaseAcquisition
                        ( projectStep
                            (fixtureProjectStepId "harness-acquired-before-refusal")
                            ProjectManagedReverse
                            "acquire before a later refusal"
                            (StepFrame "host-orchestrator-0" "metal")
                            (const recordAcquisition)
                        )
                    , projectStep
                        (fixtureProjectStepId "harness-late-refusal")
                        ProjectManagedReverse
                        "refuse after acquisition"
                        (StepFrame "host-orchestrator-0" "metal")
                        ( \_ -> do
                            modifyIORef' refused (+ 1)
                            pure (StepRefused "late acquired refusal")
                        )
                    ]
                suite =
                    TestSuite
                        (pure (Right ()))
                        (\_ -> pure ())
                        [Case (fixtureCaseId "ok") 1 False]
                        (\_ _ -> pure Pass)
                        (modifyIORef' postReverseChecks (+ 1))
                spec =
                    finalized
                        ( addSteps
                            lateRefusalChain
                            (builderWithHarnessContext stateRoot projectName suite (pure ()) [])
                        )
            ( do
                    initialized <-
                        try (withArgs ["test", "init"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                    initialized @?= Right ()
                    ran <-
                        try (withArgs ["test", "run", "all"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                    ran @?= Left (ExitFailure 1)
                    readIORef acquired >>= (@?= 2)
                    readIORef refused >>= (@?= 2)
                    readIORef reversed >>= (@?= 2)
                    -- The post-reverse hook is reached only when exact reverse,
                    -- operation-session settlement, and the terminal-close
                    -- authorization/settlement handoff all succeed; the owned
                    -- root performs final lease/mode close immediately after
                    -- this callback returns. A merely invoked reverse callback
                    -- is not enough.
                    readIORef postReverseChecks >>= (@?= 2)
                    readIORef effectRecords >>= (@?= [])
                    doesFileExist cfgPath >>= (@?= False)
                )
                `finally` removeFile testPath
        , testCase "test run refuses to overwrite an existing sibling project config" $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            let spec = specWith passingSuite (pure ()) []
            ( do
                    _ <-
                        try (withArgs ["test", "init"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                    Schema.writeProjectConfigFile
                        Fixture.projectConfigCodec
                        cfgPath
                        (Fixture.defaultProjectConfig projectName "/workspace/demo" HostOrchestrator)
                    result <-
                        try (withArgs ["test", "run", "all"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                    result @?= Left (ExitFailure 1)
                )
                `finally` (removeFile testPath >> removeFile cfgPath)
        , testCase "service schema lists variants without a config" $ do
            let spec = specWithServices Nothing [("web", pure ())]
            result <-
                try (withArgs ["service", "schema"] (runHostBootstrapCLI spec)) ::
                    IO (Either ExitCode ())
            result @?= Right ()
        , testCase "bare context schema command output matches its exact snapshot" $ do
            output <- schemaFixtureOutput "bare"
            assertGolden "context_schema_core.txt" output
        , testCase "consumer context schema command output includes its ordered artifact delta" $ do
            output <- schemaFixtureOutput "consumer"
            assertGolden "context_schema_consumer.txt" output
        , testCase "consumer service schema command output owns the project-config snapshot" $ do
            output <- schemaFixtureOutput "service"
            assertGolden "service_schema_consumer.txt" (serviceSchemaOutline output)
        , testCase "test run names a compiled case, not a suite, in its surface text" $ do
            output <- schemaFixtureOutput "test-run-help"
            assertBool
                ("the metavariable names a case id, saw " ++ T.unpack output)
                ("CASE-ID" `T.isInfixOf` output)
            assertBool
                ("the help names the whole-matrix selector, saw " ++ T.unpack output)
                (T.pack allCasesSelector `T.isInfixOf` output)
            assertBool
                ("no surface text names a suite, saw " ++ T.unpack output)
                (not ("SUITE" `T.isInfixOf` output) && not ("suite" `T.isInfixOf` output))
        , testCase "test run refuses an unknown case by naming the compiled set" $ do
            projectName <- executableProjectName
            testPath <- Schema.siblingTestConfigPath projectName
            ( do
                    _ <-
                        try (withArgs ["test", "init"] (runHostBootstrapCLI (specWith passingSuite (pure ()) []))) ::
                            IO (Either ExitCode ())
                    result <-
                        try (withArgs ["test", "run", "no-such-case"] (runHostBootstrapCLI (specWith passingSuite (pure ()) []))) ::
                            IO (Either ExitCode ())
                    result @?= Left (ExitFailure 1)
                )
                `finally` removeFile testPath
        , testCase "service run fails fast on a non-service-role config" $
            withProjectConfig $ do
                let spec = specWithServices (Just "web") [("web", pure ())]
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "service run rejects a forged multi-role orchestrator even when ServiceCommand is granted" $
            withMultiRoleHostServiceConfig $ do
                handlerRan <- newIORef False
                let spec = specWithServices (Just "web") [("web", writeIORef handlerRan True)]
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
                readIORef handlerRan >>= (@?= False)
        , testCase "service run dispatches exactly the selected variant from a multi-handler registry" $
            withServiceProjectConfig $ do
                webRan <- newIORef False
                acceleratorRan <- newIORef False
                let spec =
                        specWithServices
                            (Just "accelerator")
                            [ ("web", writeIORef webRan True)
                            , ("accelerator", writeIORef acceleratorRan True)
                            ]
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef webRan >>= (@?= False)
                readIORef acceleratorRan >>= (@?= True)
        , testCase "service run rejects a legacy positional variant" $
            withServiceProjectConfig $ do
                let spec = specWithServices (Just "web") [("web", pure ())]
                result <-
                    try (withArgs ["service", "run", "web"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "service run fails fast for an empty registry" $
            withServiceProjectConfig $ do
                let spec = specWithServices (Just "accelerator") []
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "service run fails fast for an unknown variant" $
            withServiceProjectConfig $ do
                let spec = specWithServices (Just "accelerator") [("web", pure ())]
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "service run refuses a service-role config with no configured variant" $
            withServiceProjectConfig $ do
                let spec = specWithServices Nothing [("web", pure ())]
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "the fixed service surface has no down command" $
            withServiceProjectConfig $ do
                let spec = specWithServices Nothing [("web", pure ())]
                result <-
                    try (withArgs ["service", "down"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "context render fails fast on an unknown artifact" $ do
            result <-
                try (withArgs ["context", "render", "--artifact", "missing"] (runHostBootstrapCLI (specWith passingSuite (pure ()) []))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "context render sees project artifacts from the spec" $ do
            let budgetCodec = requireCodecWitness "CLISpec.Budget" (autoCodecWitness @V.Budget)
                arts = [artifactOf "localBudget" budgetCodec (V.Budget 1 2 3)]
            result <-
                try (withArgs ["context", "render", "--artifact", "localBudget"] (runHostBootstrapCLI (specWith passingSuite (pure ()) arts))) ::
                    IO (Either ExitCode ())
            result @?= Right ()
        , testCase "project up --dry-run renders the exact plan without snapshot persistence or node effects" $
            withIsolatedProjectConfig $ \paths -> do
                let marker = isolatedCanonicalRoot paths </> "dry-run-effect"
                    markerVariable = "HOSTBOOTSTRAP_CLI_DRY_RUN_MARKER"
                previous <- lookupEnv markerVariable
                output <-
                    (setEnv markerVariable marker >> schemaFixtureOutput "project-dry-run")
                        `finally` maybe (unsetEnv markerVariable) (setEnv markerVariable) previous
                output @?= "1. [host-orchestrator-0] deploy-vm — launch the VM\n"
                doesPathExist marker >>= (@?= False)
                image <- readProtectedStoreImage (isolatedStoreRoot paths)
                lease <- expectSingleRecord ("lease." <> isolatedProjectName paths <> ".production") image
                case recordImageFields lease of
                    ["unbound", epoch] ->
                        assertBool "the dry-run lease retains a positive broker epoch" (epoch /= "0")
                    fields -> assertFailure ("expected an unbound dry-run lease, observed " ++ show fields)
                assertRecordCount "snapshot." 0 image
                assertRecordCount "acquisition." 0 image
                assertRecordCount "cursor." 0 image
                assertRecordCount "invocation." 0 image
        , testCase "project up safety refusal skips automatic project teardown" $
            withIsolatedProjectConfig $ \_paths -> do
                teardownCalls <- newIORef (0 :: Int)
                let frame = StepFrame "host-orchestrator-0" "metal"
                    refusingChain :: FixtureFragment
                    refusingChain _ _ =
                        [ reversedBy
                            (\_ _ -> writeIORef teardownCalls 1 >> pure TeardownReleased)
                            ( projectStep
                                (fixtureProjectStepId "safety-refusal")
                                ProjectManagedReverse
                                "probe ownership"
                                frame
                                (\_ -> throwIO (SafetyRefusal "pre-existing state"))
                            )
                        ]
                    spec = finalized (addSteps refusingChain (builderWith passingSuite (pure ()) []))
                result <-
                    try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
                readIORef teardownCalls >>= (@?= 0)
        , testCase "fresh project up persists and binds one exact plan before its first effect" $
            withIsolatedProjectConfig $ \paths -> do
                effects <- newIORef (0 :: Int)
                atEffect <- newIORef Nothing
                let observingChain :: FixtureFragment
                    observingChain _ _ =
                        [ projectStep
                            (fixtureProjectStepId "fresh-admission")
                            ProjectManagedReverse
                            "observe fresh admission"
                            (StepFrame "host-orchestrator-0" "metal")
                            ( \_ -> do
                                modifyIORef' effects (+ 1)
                                readProtectedStoreImage (isolatedStoreRoot paths)
                                    >>= writeIORef atEffect . Just
                                pure StepChanged
                            )
                        ]
                    spec =
                        finalized $
                            addSteps observingChain $
                                builderWith passingSuite (pure ()) []
                result <-
                    try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef effects >>= (@?= 1)
                readIORef atEffect >>= \case
                    Nothing -> assertFailure "the fresh plan effect never observed its durable admission"
                    Just image -> do
                        snapshot <- expectSingleRecord ("snapshot." <> isolatedProjectName paths <> ".production") image
                        assertBool "the exact snapshot is present before the effect" (not (ByteString.null (let (_, _, bytes) = snapshot in bytes)))
                        lease <- expectSingleRecord ("lease." <> isolatedProjectName paths <> ".production") image
                        case recordImageFields lease of
                            ["bound", epoch, specDigest, planDigest] -> do
                                assertBool "the bound lease retains a positive broker epoch" (epoch /= "0")
                                assertBool "the bound lease carries a specification digest" (not (T.null specDigest))
                                assertBool "the bound lease carries a plan digest" (not (T.null planDigest))
                            fields -> assertFailure ("expected a bound fresh lease, observed " ++ show fields)
                        assertRecordCount "acquisition." 1 image
                        assertRecordCount "cursor." 1 image
                        assertRecordCount "invocation." 1 image
                finalImage <- readProtectedStoreImage (isolatedStoreRoot paths)
                cursor <- expectSingleRecord "cursor." finalImage
                assertBool "the completed fresh invocation advances its cursor to teardown" (recordImageContains "teardown" cursor)
        , testCase "project up persists one exact recursive catalog manifest before its first effect" $
            withIsolatedProjectConfig $ \paths -> do
                atEffect <- newIORef Nothing
                let observingChain :: FixtureFragment
                    observingChain _ _ =
                        [ projectStep
                            (fixtureProjectStepId "catalog-admission")
                            ProjectManagedReverse
                            "observe the admitted catalog"
                            (StepFrame "host-orchestrator-0" "metal")
                            ( \_ -> do
                                readProtectedStoreImage (isolatedStoreRoot paths)
                                    >>= writeIORef atEffect . Just
                                pure StepChanged
                            )
                        ]
                    spec =
                        finalized $
                            addSteps observingChain $
                                builderWith passingSuite (pure ()) []
                result <-
                    try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef atEffect >>= \case
                    Nothing -> assertFailure "the admitted catalog was never observed at the first effect"
                    Just image -> do
                        lease <- expectSingleRecord ("lease." <> isolatedProjectName paths <> ".production") image
                        (epoch, specDigest, planDigest) <-
                            case recordImageFields lease of
                                ["bound", epochField, specField, planField] ->
                                    pure (epochField, specField, planField)
                                fields -> assertFailure ("expected a bound lease, observed " ++ show fields)
                        (catalogKey, catalogVersion, catalogBytes) <- expectSingleRecord "catalog." image
                        catalogKey
                            @?= "catalog.." <> isolatedProjectName paths <> "..production.." <> epoch
                        catalogVersion @?= 1
                        assertBool
                            "the durable manifest opens with the framed catalog tag"
                            ( ByteString.isPrefixOf
                                ( LazyByteString.toStrict
                                    ( Builder.toLazyByteString
                                        ( Builder.word64BE
                                            (fromIntegral (ByteString.length catalogTag))
                                            <> Builder.byteString catalogTag
                                            <> Builder.word64BE 1
                                        )
                                    )
                                )
                                catalogBytes
                            )
                        mapM_
                            ( \(label, value) ->
                                assertBool
                                    ("the durable manifest omits its " ++ label)
                                    ( ByteString.isInfixOf
                                        (TextEncoding.encodeUtf8 value)
                                        catalogBytes
                                    )
                            )
                            [ ("installed project", isolatedProjectName paths)
                            , ("stable profile", "production")
                            , ("specification digest", specDigest)
                            , ("root plan digest", planDigest)
                            , ("root frame", "host-orchestrator-0")
                            ]
                        assertBool
                            "a single-frame root plan admits a descent edge"
                            ( ByteString.isSuffixOf
                                (ByteString.replicate 8 0)
                                catalogBytes
                            )
        , testCase "an exact project up retry converges on the recursive catalog it already persisted" $
            withIsolatedProjectConfig $ \paths -> do
                effects <- newIORef (0 :: Int)
                let conflictingChain :: FixtureFragment
                    conflictingChain _ _ =
                        [ projectStep
                            (fixtureProjectStepId "catalog-retry")
                            ProjectManagedReverse
                            "reserve then stop"
                            (StepFrame "host-orchestrator-0" "metal")
                            ( \_ -> do
                                modifyIORef' effects (+ 1)
                                pure (StepConflict "healthy" "conflicting" "repair the fixture")
                            )
                        ]
                    spec = finalized (addSteps conflictingChain (builderWith passingSuite (pure ()) []))
                    run =
                        try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                run >>= (@?= Left (ExitFailure 1))
                readIORef effects >>= (@?= 1)
                persisted <- readProtectedStoreImage (isolatedStoreRoot paths)
                catalog <- expectSingleRecord "catalog." persisted
                run >>= (@?= Left (ExitFailure 1))
                readIORef effects >>= (@?= 1)
                replayed <- readProtectedStoreImage (isolatedStoreRoot paths)
                assertRecordCount "catalog." 1 replayed
                expectSingleRecord "catalog." replayed >>= (@?= catalog)
        , testCase "a conflicting durable recursive catalog refuses before the reservation" $
            withIsolatedProjectConfig $ \paths -> do
                effects <- newIORef (0 :: Int)
                let refusedChain :: FixtureFragment
                    refusedChain _ _ =
                        [ projectStep
                            (fixtureProjectStepId "catalog-conflict")
                            ProjectManagedReverse
                            "must not run"
                            (StepFrame "host-orchestrator-0" "metal")
                            (\_ -> modifyIORef' effects (+ 1) >> pure StepChanged)
                        ]
                    spec = finalized (addSteps refusedChain (builderWith passingSuite (pure ()) []))
                before <- seedBoundExecute paths spec
                lease <- expectSingleRecord ("lease." <> isolatedProjectName paths <> ".production") before
                epoch <-
                    case recordImageFields lease of
                        ["bound", epochField, _specDigest, _planDigest] -> pure epochField
                        fields -> assertFailure ("expected a bound seeded lease, observed " ++ show fields)
                assertRecordCount "catalog." 0 before
                assertRecordCount "invocation." 0 before
                let foreignKey =
                        "catalog.." <> isolatedProjectName paths <> "..production.." <> epoch
                    foreignBytes = "not-the-admitted-recursive-catalog"
                writeForeignRecord (isolatedStoreRoot paths) foreignKey foreignBytes
                result <-
                    try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
                readIORef effects >>= (@?= 0)
                after <- readProtectedStoreImage (isolatedStoreRoot paths)
                assertRecordCount "invocation." 0 after
                expectSingleRecord "catalog." after
                    >>= (@?= (foreignKey, 1, foreignBytes))
        , testCase "a declared descent is recursively projected before any effect or reservation" $
            withIsolatedProjectConfig $ \paths -> do
                effects <- newIORef (0 :: Int)
                let descendingChain :: FixtureFragment
                    descendingChain _ _ =
                        [ descendsVia
                            (inVM (IncusVM "fixture-vm" "images:ubuntu/24.04") localContext)
                            ( projectStep
                                (fixtureProjectStepId "catalog-descent-parent")
                                PreserveOnReverse
                                "offer the declared descent"
                                (StepFrame "host-orchestrator-0" "metal")
                                (\_ -> modifyIORef' effects (+ 1) >> pure StepChanged)
                            )
                        , projectStep
                            (fixtureProjectStepId "catalog-descent-child")
                            PreserveOnReverse
                            "work inside the declared child frame"
                            (StepFrame "vm-orchestrator-1" "VM")
                            (\_ -> modifyIORef' effects (+ 1) >> pure StepChanged)
                        ]
                    spec = finalized (addSteps descendingChain (builderWith passingSuite (pure ()) []))
                result <-
                    try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
                readIORef effects >>= (@?= 0)
                image <- readProtectedStoreImage (isolatedStoreRoot paths)
                assertRecordCount "catalog." 0 image
                assertRecordCount "invocation." 0 image
        , testCase "an admitted one-layer descent is cataloged with its exact edge before the first effect" $
            withIsolatedProjectConfig $ \paths -> do
                atEffect <- newIORef Nothing
                let admittedSteps =
                        [ descendsVia
                            (inVM (IncusVM "fixture-vm" "images:ubuntu/24.04") localContext)
                            ( projectStep
                                (fixtureProjectStepId "admitted-descent-parent")
                                PreserveOnReverse
                                "offer the admitted descent"
                                (StepFrame "host-orchestrator-0" "metal")
                                {- The catalog is admitted before the reservation
                                and before this first effect, so the run is
                                halted here rather than descending: executing a
                                real remote frame is later-sprint work and must
                                not depend on a live provider. -}
                                ( \_ -> do
                                    readProtectedStoreImage (isolatedStoreRoot paths)
                                        >>= writeIORef atEffect . Just
                                    pure (StepConflict "healthy" "halted" "stop before the descent")
                                )
                            )
                        , projectStep
                            (fixtureProjectStepId "admitted-descent-child")
                            PreserveOnReverse
                            "work inside the admitted child frame"
                            (StepFrame "vm-orchestrator-1" "VM")
                            (\_ -> pure StepChanged)
                        ]
                    spec =
                        finalized $
                            addSteps (\_ _ -> admittedSteps) $
                                builderWithProjectingChild
                                    "/workspace/demo"
                                    admittedSteps
                                    passingSuite
                                    (pure ())
                                    []
                result <-
                    try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
                readIORef atEffect >>= \case
                    Nothing -> assertFailure "the admitted catalog was never observed at the first effect"
                    Just image -> do
                        lease <- expectSingleRecord ("lease." <> isolatedProjectName paths <> ".production") image
                        epoch <-
                            case recordImageFields lease of
                                ["bound", epochField, _specDigest, _planDigest] -> pure epochField
                                fields -> assertFailure ("expected a bound lease, observed " ++ show fields)
                        (catalogKey, catalogVersion, catalogBytes) <- expectSingleRecord "catalog." image
                        catalogKey
                            @?= "catalog.." <> isolatedProjectName paths <> "..production.." <> epoch
                        catalogVersion @?= 1
                        let framed value =
                                let encoded = TextEncoding.encodeUtf8 value
                                 in Builder.word64BE (fromIntegral (ByteString.length encoded))
                                        <> Builder.byteString encoded
                        assertBool
                            "the durable manifest frames exactly one admitted descent edge"
                            ( ByteString.isInfixOf
                                ( LazyByteString.toStrict
                                    ( Builder.toLazyByteString
                                        ( Builder.word64BE 1
                                            <> framed "host-orchestrator-0"
                                            <> framed "vm-orchestrator-1"
                                        )
                                    )
                                )
                                catalogBytes
                            )
        , testCase "project up resumes an exact persisted snapshot whose lease is still unbound" $
            withIsolatedProjectConfig $ \paths -> do
                effects <- newIORef (0 :: Int)
                let retryChain :: FixtureFragment
                    retryChain _ _ =
                        [ projectStep
                            (fixtureProjectStepId "persisted-unbound-retry")
                            ProjectManagedReverse
                            "resume the partially persisted invocation"
                            (StepFrame "host-orchestrator-0" "metal")
                            (\_ -> modifyIORef' effects (+ 1) >> pure StepChanged)
                        ]
                    spec = finalized (addSteps retryChain (builderWith passingSuite (pure ()) []))
                snapshotBefore <- seedPersistedUnbound paths spec
                before <- readProtectedStoreImage (isolatedStoreRoot paths)
                leaseBefore <- expectSingleRecord ("lease." <> isolatedProjectName paths <> ".production") before
                case recordImageFields leaseBefore of
                    ["unbound", _epoch] -> pure ()
                    fields -> assertFailure ("expected the seeded lease to remain unbound, observed " ++ show fields)
                assertRecordCount "acquisition." 0 before
                assertRecordCount "cursor." 0 before
                assertRecordCount "invocation." 0 before
                result <-
                    try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef effects >>= (@?= 1)
                after <- readProtectedStoreImage (isolatedStoreRoot paths)
                snapshotAfter <- expectSingleRecord ("snapshot." <> isolatedProjectName paths <> ".production") after
                snapshotAfter @?= snapshotBefore
                leaseAfter <- expectSingleRecord ("lease." <> isolatedProjectName paths <> ".production") after
                case recordImageFields leaseAfter of
                    ["bound", _epoch, _specDigest, _planDigest] -> pure ()
                    fields -> assertFailure ("expected the retry to bind the retained lease, observed " ++ show fields)
                assertRecordCount "acquisition." 1 after
                assertRecordCount "cursor." 1 after
                assertRecordCount "invocation." 1 after
        , testCase "project up recovers one bound Open invocation from its Execute cursor" $
            withIsolatedProjectConfig $ \paths -> do
                effects <- newIORef (0 :: Int)
                let recoveryChain :: FixtureFragment
                    recoveryChain _ _ =
                        [ projectStep
                            (fixtureProjectStepId "bound-open-recovery")
                            ProjectManagedReverse
                            "resume the bound open invocation"
                            (StepFrame "host-orchestrator-0" "metal")
                            (\_ -> modifyIORef' effects (+ 1) >> pure StepChanged)
                        ]
                    spec = finalized (addSteps recoveryChain (builderWith passingSuite (pure ()) []))
                before <- seedBoundExecute paths spec
                snapshotBefore <- expectSingleRecord ("snapshot." <> isolatedProjectName paths <> ".production") before
                leaseBefore <- expectSingleRecord ("lease." <> isolatedProjectName paths <> ".production") before
                acquisitionBefore <- expectSingleRecord "acquisition." before
                cursorBefore@(_, cursorVersionBefore, _) <- expectSingleRecord "cursor." before
                assertBool "the recovery seed stops at Execute" (recordImageContains "execute" cursorBefore)
                assertRecordCount "invocation." 0 before
                result <-
                    try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef effects >>= (@?= 1)
                after <- readProtectedStoreImage (isolatedStoreRoot paths)
                expectSingleRecord ("snapshot." <> isolatedProjectName paths <> ".production") after >>= (@?= snapshotBefore)
                expectSingleRecord ("lease." <> isolatedProjectName paths <> ".production") after >>= (@?= leaseBefore)
                expectSingleRecord "acquisition." after >>= (@?= acquisitionBefore)
                cursorAfter@(_, cursorVersionAfter, _) <- expectSingleRecord "cursor." after
                cursorVersionAfter @?= cursorVersionBefore + 1
                assertBool "the recovered invocation advances the same cursor to teardown" (recordImageContains "teardown" cursorAfter)
                assertRecordCount "invocation." 1 after
        , testCase "project up Teardown recovery returns without a second entry, effect, or reservation" $
            withIsolatedProjectConfig $ \paths -> do
                effects <- newIORef (0 :: Int)
                let completedChain :: FixtureFragment
                    completedChain _ _ =
                        [ projectStep
                            (fixtureProjectStepId "completed-entry-replay")
                            ProjectManagedReverse
                            "complete once"
                            (StepFrame "host-orchestrator-0" "metal")
                            (\_ -> modifyIORef' effects (+ 1) >> pure StepChanged)
                        ]
                    spec = finalized (addSteps completedChain (builderWith passingSuite (pure ()) []))
                    run =
                        try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                run >>= (@?= Right ())
                readIORef effects >>= (@?= 1)
                completed <- readProtectedStoreImage (isolatedStoreRoot paths)
                completedCursor <- expectSingleRecord "cursor." completed
                assertBool "the first run reached Teardown" (recordImageContains "teardown" completedCursor)
                completedInvocation <- expectSingleRecord "invocation." completed
                run >>= (@?= Right ())
                readIORef effects >>= (@?= 1)
                replayed <- readProtectedStoreImage (isolatedStoreRoot paths)
                expectSingleRecord "cursor." replayed >>= (@?= completedCursor)
                expectSingleRecord "invocation." replayed >>= (@?= completedInvocation)
                assertRecordCount "invocation." 1 replayed
        , testCase "project up Execute recovery refuses a consumed reservation without rerunning its callback" $
            withIsolatedProjectConfig $ \paths -> do
                effects <- newIORef (0 :: Int)
                let conflictingChain :: FixtureFragment
                    conflictingChain _ _ =
                        [ projectStep
                            (fixtureProjectStepId "consumed-entry-replay")
                            ProjectManagedReverse
                            "reserve then stop"
                            (StepFrame "host-orchestrator-0" "metal")
                            ( \_ -> do
                                modifyIORef' effects (+ 1)
                                pure (StepConflict "healthy" "conflicting" "repair the fixture")
                            )
                        ]
                    spec = finalized (addSteps conflictingChain (builderWith passingSuite (pure ()) []))
                    run =
                        try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                first <- run
                first @?= Left (ExitFailure 1)
                readIORef effects >>= (@?= 1)
                consumed <- readProtectedStoreImage (isolatedStoreRoot paths)
                consumedCursor <- expectSingleRecord "cursor." consumed
                assertBool "the failed interpreter retains Execute" (recordImageContains "execute" consumedCursor)
                consumedInvocation <- expectSingleRecord "invocation." consumed
                second <- run
                second @?= Left (ExitFailure 1)
                readIORef effects >>= (@?= 1)
                replayed <- readProtectedStoreImage (isolatedStoreRoot paths)
                expectSingleRecord "cursor." replayed >>= (@?= consumedCursor)
                expectSingleRecord "invocation." replayed >>= (@?= consumedInvocation)
                assertRecordCount "invocation." 1 replayed
        , -- `project down` is the plan's own reverse projection, so the effect it
          -- runs is the one the acquiring step declared — not a whole-project
          -- hook beside the plan (§ W). The chain here owns no `deploy-kind`, so
          -- the core cluster adapter contributes nothing and only this node runs.
          testCase "project down runs the reverse the acquiring step declared" $
            withIsolatedProjectConfig $ \_paths -> do
                observed <- newIORef ([] :: [TeardownAction])
                let reversedChain :: FixtureFragment
                    reversedChain _ _ =
                        [ reversedBy
                            (\_ action -> modifyIORef' observed (action :) >> pure TeardownReleased)
                            (deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (const (pure StepChanged)))
                        ]
                    spec = finalized (addSteps reversedChain (builderWith passingSuite (pure ()) []))
                result <-
                    try (withArgs ["project", "down"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                -- `down` stops a provider frame; `destroy` deletes it. That one
                -- difference is the whole of the verb indexing.
                readIORef observed >>= (@?= [StopFrame])
                writeIORef observed []
                destroyResult <-
                    try (withArgs ["project", "destroy"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                destroyResult @?= Right ()
                readIORef observed >>= (@?= [DeleteFrame])
        , testCase "chain steps see the snapshot admitted at project up, not a replaced sibling" $
            withIsolatedProjectConfig $ \paths -> do
                let projectName = isolatedProjectName paths
                    path = isolatedConfigPath paths
                seen <- newIORef ([] :: [(T.Text, T.Text)])
                let frame = StepFrame "host-orchestrator-0" "metal"
                    admitted = Fixture.defaultProjectConfig projectName "." HostOrchestrator
                    replaced = admitted{Fixture.dockerfile = "replaced-mid-run.Dockerfile"}
                    -- Step one replaces @<project>.dhall@ underneath the running
                    -- chain; step two records both what its injected snapshot
                    -- says and what a fresh read of the file would have said.
                    toctouChain :: FixtureFragment
                    toctouChain _ cfg =
                        [ projectStep
                            (fixtureProjectStepId "replace-sibling")
                            ProjectManagedReverse
                            "replace the sibling config mid-run"
                            frame
                            ( \_ -> do
                                Schema.writeProjectConfigFile Fixture.projectConfigCodec path replaced
                                pure StepChanged
                            )
                        , projectStep
                            (fixtureProjectStepId "observe-config")
                            ProjectManagedReverse
                            "record the config this step runs against"
                            frame
                            ( \_ -> do
                                onDisk <- Fixture.decodeProjectConfigFile path
                                modifyIORef' seen ((Fixture.dockerfile cfg, Fixture.dockerfile onDisk) :)
                                pure StepChanged
                            )
                        ]
                    spec =
                        finalized $
                            addSteps toctouChain (builderWith passingSuite (pure ()) [])
                result <-
                    try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                -- The step kept the admitted snapshot even though a reload at
                -- that same instant would have returned different bytes.
                readIORef seen
                    >>= (@?= [(Fixture.dockerfile admitted, "replaced-mid-run.Dockerfile")])
        , testCase "Production command source has one exact plan route and no compatibility escape" $ do
            cwd <- getCurrentDirectory
            repoRoot <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
            let packageRoot = repoRoot </> "core" </> "hostbootstrap-core"
                sourceRoot = packageRoot </> "src" </> "HostBootstrap"
            commandSource <- TIO.readFile (sourceRoot </> "Command.hs")
            entrySource <-
                TIO.readFile
                    (sourceRoot </> "Command" </> "LifecycleEntry.hs")
            reconcileSource <- TIO.readFile (sourceRoot </> "Reconcile.hs")
            teardownSource <- TIO.readFile (sourceRoot </> "Teardown.hs")
            cabalSource <- TIO.readFile (packageRoot </> "hostbootstrap-core.cabal")
            sources <- lifecycleHaskellSources sourceRoot
            entryImporters <-
                filterM
                    (fmap (T.isInfixOf "import HostBootstrap.Command.LifecycleEntry") . TIO.readFile)
                    sources
            let projectStart = "projectCommandGroup ::"
                projectEnd = "-- | Whether the current binary frame owns"
                fromProject = snd (T.breakOn projectStart commandSource)
                productionSlice = fst (T.breakOn projectEnd fromProject)
                normalized = T.unwords (T.words productionSlice)
                require fragment =
                    assertBool
                        ("Production command lost its exact route: " ++ T.unpack fragment)
                        (fragment `T.isInfixOf` normalized)
                forbid label source fragment =
                    assertBool
                        (label ++ " still contains compatibility shape " ++ T.unpack fragment)
                        (not (fragment `T.isInfixOf` source))
            assertBool "could not isolate projectCommandGroup" (not (T.null fromProject) && projectEnd `T.isInfixOf` fromProject)
            sort (map (makeRelative sourceRoot) entryImporters)
                @?= [ "Command.hs"
                    , "Handoff/Lifecycle.hs"
                    ]
            mapM_
                require
                [ "withProjectPlan profile root validated drafts"
                , "withRecoveredProductionProjectPlan profile root verified bound binding recoveredConfig recoveredDrafts"
                , "case withCurrentFrame plan ctx"
                , "SnapshotVerificationError (ModeWrongMode \"production\" \"absent\") -> True"
                , "SnapshotVerificationError (ModeLeaseNotBindable \"production\" \"unbound\") -> True"
                , "LifecycleContext.withValidatedLifecycleContext"
                , "runExactProjectUp"
                , "withRootProjectUpLifecycleEntry"
                , "runRootProjectUpLifecycleEntry"
                , "withRootProjectUpLifecycleEntry exactSpec rootAuthority Authority.ProjectUp verified bound binding lease plan lifecycleContext (runRootProjectUpLifecycleEntry cfg self)"
                , "Teardown.teardownPlan plan currentFrame verb"
                ]
            mapM_
                ( \fragment ->
                    assertBool
                        ("hidden lifecycle entry lost its exact route: " ++ T.unpack fragment)
                        (fragment `T.isInfixOf` T.unwords (T.words entrySource))
                )
                [ "withValidatedRootLifecycleContext"
                , "withAcquisitionJournal"
                , "withCurrentLifecycleCursor journal frame verb"
                , "withRootedPlanCatalogKernel finalized rootAuthority plan current lifecycleContext"
                , "settleRootedPlanCatalog store catalog"
                , "compareAndSwapProtectedRecord session key ExpectAbsent manifest"
                , "rootedPlanCatalogManifestMatchesKernel catalog (protectedRecordBytes record)"
                , "ProjectAuthority.authorizeRootProject"
                , "runChainFromFrame cfg self store plan authority cursor"
                , "withTeardownLifecycleCursor cursor"
                ]
            T.count "withProjectPlan profile root validated drafts" normalized @?= 1
            T.count "withRecoveredProductionProjectPlan profile root verified bound binding recoveredConfig recoveredDrafts" normalized @?= 1
            T.count "withRootProjectUpLifecycleEntry" normalized @?= 1
            mapM_
                (forbid "Production command" productionSlice)
                [ "projectPlanStepPlan"
                , "withLifecyclePlan"
                , "LifecyclePlan"
                , "StepPlan"
                , "HostBootstrap.Chain.Compatibility"
                , "compatibilityStepExecutionFor"
                , "withCompatibilityTeardownPlan"
                , "ProjectAuthority.authorizeRootProject"
                , "runChainFromFrame cfg self store plan"
                , "withCurrentLifecycleCursor"
                ]
            assertBool "Command must import the public Chain facade" ("import HostBootstrap.Chain (" `T.isInfixOf` commandSource)
            forbid "Command" commandSource "HostBootstrap.Chain.Compatibility"
            forbid "Reconcile" reconcileSource "compatibilityStepExecutionFor"
            forbid "Teardown" teardownSource "withCompatibilityTeardownPlan"
            forbid "Teardown" teardownSource "compatibilityReverseStepFor"
            forbid "Cabal" cabalSource "HostBootstrap.Chain.Compatibility"
            assertBool
                "the lifecycle entry implementation must remain Cabal-hidden"
                ( "other-modules: HostBootstrap.Authority.Kernel HostBootstrap.Authority.ProjectPlan.Internal HostBootstrap.Command.LifecycleEntry"
                    `T.isInfixOf` T.unwords (T.words cabalSource)
                )
            doesFileExist (sourceRoot </> "Chain" </> "Compatibility.hs") >>= (@?= False)
        , testCase "project up fails fast without a sibling context" $ do
            result <-
                try (withArgs ["project", "up", "--dry-run"] (runHostBootstrapCLI (specWith passingSuite (pure ()) []))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        ]

specWithServices ::
    Maybe String ->
    [(String, IO ())] ->
    ProjectSpec Fixture.ProjectConfig Fixture.TestConfig
specWithServices selected handlers =
    finalized $
        addServices
            (fixtureServiceRegistry selected handlers)
            ( addSteps sampleChain $
                builderWith passingSuite (pure ()) []
            )

fixtureServiceRegistry ::
    Maybe String ->
    [(String, IO ())] ->
    ServiceRegistry Fixture.ProjectConfig
fixtureServiceRegistry selected handlers =
    either (error . show) id $
        serviceRegistry
            [ serviceDefinition
                (either error id (serviceId name))
                (\_ -> Right (if selected == Just name then Just () else Nothing))
                -- The fixture declares a listen-only row: enough that the
                -- selection carries a real declaration, narrow enough that a
                -- widening would show up as a diff here.
                (WithEffect NetworkListenName NoEffects)
                (\_ -> handler)
            | (name, handler) <- handlers
            ]

{- | One additive step fragment. Rank-2 in the admitted root, so a fragment can
derive project-relative paths from it without ever seeing its phantoms.
-}
type FixtureFragment =
    forall scope rootId.
    CanonicalProjectRoot scope rootId ->
    Fixture.ProjectConfig scope ->
    [Step]

-- A compile-time-only generative run index for the scope-polymorphic planner
-- case above. No authority is minted from this descriptive fixture type.
data HarnessPlanRun

-- A one-step demo-shaped chain used to prove `project up --dry-run` renders.
sampleChain :: FixtureFragment
sampleChain _ _ =
    [deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (const (pure StepChanged))]

fixtureProjectStepId :: String -> ProjectStepId
fixtureProjectStepId = either error id . projectStepId

lifecycleHaskellSources :: FilePath -> IO [FilePath]
lifecycleHaskellSources directory = do
    entries <- listDirectory directory
    let paths = map (directory </>) entries
    directories <- filterM doesDirectoryExist paths
    nested <- concat <$> mapM lifecycleHaskellSources directories
    pure ([path | path <- paths, takeExtension path == ".hs"] <> nested)

{- | One CLI invocation gets its own absolute canonical root and therefore its
own protected Production store.  The executable-sibling config path is fixed
by the real CLI contract, but no durable authority row is shared with another
case.
-}
data IsolatedProductionPaths = IsolatedProductionPaths
    { isolatedProjectName :: T.Text
    , isolatedConfigPath :: FilePath
    , isolatedCanonicalRoot :: FilePath
    , isolatedStoreRoot :: FilePath
    }

withIsolatedProjectConfig :: (IsolatedProductionPaths -> IO result) -> IO result
withIsolatedProjectConfig use =
    withSystemTempDirectory "hostbootstrap-cli-production" $ \configuredRoot -> do
        projectName <- executableProjectName
        configPath <- Schema.siblingProjectConfigPath projectName
        rooted <-
            withCanonicalProjectRoot
                configPath
                configuredRoot
                (pure . canonicalProjectRootPath)
        canonicalRoot <- either (assertFailure . show) pure rooted
        let config =
                Fixture.defaultProjectConfig
                    projectName
                    (T.pack canonicalRoot)
                    HostOrchestrator
            cleanup = do
                present <- doesFileExist configPath
                if present then removeFile configPath else pure ()
        ( do
                Schema.writeProjectConfigFile Fixture.projectConfigCodec configPath config
                use
                    IsolatedProductionPaths
                        { isolatedProjectName = projectName
                        , isolatedConfigPath = configPath
                        , isolatedCanonicalRoot = canonicalRoot
                        , isolatedStoreRoot =
                            canonicalRoot
                                </> ".hostbootstrap"
                                </> "authority"
                                </> T.unpack projectName
                        }
            )
            `finally` cleanup

type ProtectedRecordImage = (T.Text, Word64, ByteString.ByteString)

readProtectedStoreImage :: FilePath -> IO [ProtectedRecordImage]
readProtectedStoreImage storeRoot = do
    store <- openProtectedStore storeRoot >>= either (assertFailure . show) pure
    entered <-
        withProtectedEntry store $ \session -> do
            keys <- listProtectedRecords session >>= either (assertFailure . show) pure
            rows <-
                mapM
                    ( \key -> do
                        observed <- readProtectedRecord session key >>= either (assertFailure . show) pure
                        record <-
                            maybe
                                (assertFailure ("protected record disappeared: " ++ T.unpack (recordKeyText key)))
                                pure
                                observed
                        pure
                            ( recordKeyText key
                            , recordVersionWord (protectedRecordVersion record)
                            , protectedRecordBytes record
                            )
                    )
                    keys
            pure (Right rows)
    either (assertFailure . show) pure entered

recordsWithPrefix :: T.Text -> [ProtectedRecordImage] -> [ProtectedRecordImage]
recordsWithPrefix prefix = filter (T.isPrefixOf prefix . recordImageKey)
  where
    recordImageKey (key, _, _) = key

assertRecordCount :: T.Text -> Int -> [ProtectedRecordImage] -> IO ()
assertRecordCount prefix expected image =
    length (recordsWithPrefix prefix image) @?= expected

expectSingleRecord :: T.Text -> [ProtectedRecordImage] -> IO ProtectedRecordImage
expectSingleRecord prefix image =
    case recordsWithPrefix prefix image of
        [record] -> pure record
        observed ->
            assertFailure
                ( "expected one protected record with prefix "
                    ++ T.unpack prefix
                    ++ ", observed "
                    ++ show (map (\(key, _, _) -> key) observed)
                )

recordImageFields :: ProtectedRecordImage -> [T.Text]
recordImageFields (_, _, bytes) =
    map (T.pack . ByteStringChar8.unpack) (ByteStringChar8.split '\t' bytes)

recordImageContains :: T.Text -> ProtectedRecordImage -> Bool
recordImageContains needle (_, _, bytes) =
    TextEncoding.encodeUtf8 needle `ByteString.isInfixOf` bytes

expectRight :: (Show failure) => Either failure result -> IO result
expectRight = either (assertFailure . show) pure

{- | Admit the exact finalized Production plan the CLI will reconstruct from
the same static spec and on-disk config.  The callback cannot retain any of the
fresh local identities.
-}
withExactSeedPlan ::
    IsolatedProductionPaths ->
    ProjectSpec Fixture.ProjectConfig Fixture.TestConfig ->
    ( forall projectId brokerGeneration specDigest planId configId rootId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      ProductionRoot projectId brokerGeneration Authority.VerbUp ->
      CanonicalProjectRoot (V.Production projectId) rootId ->
      ProjectPlan
        (V.Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      Context.BinaryContext ->
      IO result
    ) ->
    IO result
withExactSeedPlan paths spec use = do
    store <- openProtectedStore (isolatedStoreRoot paths) >>= either (assertFailure . show) pure
    installed <-
        withInstalledProjectIdentity (isolatedProjectName paths) $ \(project :: InstalledProjectIdentity projectId) -> do
            rooted <-
                withCanonicalProjectRoot
                    (isolatedConfigPath paths)
                    (isolatedCanonicalRoot paths)
                    ( \(root :: CanonicalProjectRoot (V.Production projectId) rootId) -> do
                        started <-
                            withProductionRoot store project Authority.ProjectUp $ \productionRoot -> do
                                let rootAuthority = productionRootAuthority productionRoot
                                    unbound = productionRootUnboundLease productionRoot
                                profiled <-
                                    withProductionLifecycleProfile
                                        (Authority.rootScopeAuthority rootAuthority)
                                        (productionActiveMode (productionRootModeLease productionRoot))
                                        unbound
                                        ( \profile ->
                                            withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \baseCodec ->
                                                withFinalizedProjectSpec
                                                    ProductionScope
                                                    baseCodec
                                                    emptyServiceRegistry
                                                    (projectStepPlan spec)
                                                    Fixture.refusingForwardChildPlan
                                                    ( \finalizedSpec -> do
                                                        let value =
                                                                Fixture.defaultProjectConfig
                                                                    (installedProjectName project)
                                                                    (T.pack (isolatedCanonicalRoot paths))
                                                                    HostOrchestrator
                                                        validated <-
                                                            Schema.withValidatedConfig
                                                                (finalizedProjectCodec finalizedSpec)
                                                                value
                                                                ( \_wire config -> do
                                                                    drafts <- expectRight (projectPlanDrafts finalizedSpec root config)
                                                                    planAction <-
                                                                        expectRight
                                                                            ( withProjectPlan
                                                                                profile
                                                                                root
                                                                                config
                                                                                drafts
                                                                                ( \plan ->
                                                                                    use
                                                                                        store
                                                                                        project
                                                                                        productionRoot
                                                                                        root
                                                                                        plan
                                                                                        (Fixture.context value)
                                                                                )
                                                                            )
                                                                    planAction
                                                                )
                                                        either assertFailure pure validated
                                                    )
                                        )
                                action <- either (assertFailure . T.unpack . authorityErrorMessage) pure profiled
                                Right <$> action
                        expectRight started
                    )
            expectRight rooted
    either (assertFailure . T.unpack . authorityErrorMessage) pure installed

writeExactStableSnapshot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ProjectPlan scope specDigest planId configId cfg ->
    IO ProtectedRecordImage
writeExactStableSnapshot store project plan = do
    let stable = renderSnapshot plan
        keyText = "snapshot." <> installedProjectName project <> ".production"
        key = either (error . show) id (mkRecordKey keyText)
        canonicalBytes = stablePlanSnapshotBytes stable
        encodeBytes bytes =
            Builder.word64BE (fromIntegral (ByteString.length bytes))
                <> Builder.byteString bytes
        encodeText = encodeBytes . TextEncoding.encodeUtf8
        payload =
            LazyByteString.toStrict
                ( Builder.toLazyByteString
                    ( Builder.byteString "HOSTBOOTSTRAP-SNAPSHOT"
                        <> Builder.word64BE 1
                        <> Builder.word64BE 1
                        <> encodeText (stablePlanSnapshotSpecDigest stable)
                        <> encodeText (stablePlanSnapshotDigest stable)
                        <> Builder.word8 1
                        <> encodeText (stablePlanSnapshotConfigDigest stable)
                        <> encodeBytes canonicalBytes
                    )
                )
    written <-
        withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord session key ExpectAbsent payload
    _ <- expectRight written
    image <- readProtectedStoreImage (isolatedStoreForPlan stable)
    expectSingleRecord keyText image
  where
    -- Stable snapshots expose the canonical root used by the command.  The
    -- store path is therefore derived from that authority, never from cwd.
    isolatedStoreForPlan stable =
        stablePlanSnapshotRoot stable
            </> ".hostbootstrap"
            </> "authority"
            </> T.unpack (installedProjectName project)

-- | The framed vocabulary tag every recursive catalog manifest opens with.
catalogTag :: ByteString.ByteString
catalogTag = "hostbootstrap/rooted-plan-catalog"

{- | Publish one foreign durable record under an exact key.

The lifecycle never writes these bytes, so a run that accepts them has stopped
comparing the durable manifest with the catalog it admitted.
-}
writeForeignRecord :: FilePath -> T.Text -> ByteString.ByteString -> IO ()
writeForeignRecord storeRoot keyText bytes = do
    store <- openProtectedStore storeRoot >>= either (assertFailure . show) pure
    key <- either (assertFailure . show) pure (mkRecordKey keyText)
    written <-
        withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord session key ExpectAbsent bytes
    _ <- expectRight written
    pure ()

seedPersistedUnbound ::
    IsolatedProductionPaths ->
    ProjectSpec Fixture.ProjectConfig Fixture.TestConfig ->
    IO ProtectedRecordImage
seedPersistedUnbound paths spec =
    withExactSeedPlan paths spec $ \store project _productionRoot _root plan _context ->
        writeExactStableSnapshot store project plan

seedBoundExecute ::
    IsolatedProductionPaths ->
    ProjectSpec Fixture.ProjectConfig Fixture.TestConfig ->
    IO [ProtectedRecordImage]
seedBoundExecute paths spec =
    withExactSeedPlan paths spec $ \_store _project productionRoot _root plan context -> do
        let rootAuthority = productionRootAuthority productionRoot
            unbound = productionRootUnboundLease productionRoot
        persisted <-
            withPersistedPlanSnapshot
                rootAuthority
                unbound
                plan
                ( \_verified bound binding lease _normalRecovery -> do
                    framed <-
                        expectRight
                            ( withCurrentFrame plan context $ \_current frame _validated -> do
                                journaled <-
                                    withAcquisitionJournal
                                        rootAuthority
                                        lease
                                        bound
                                        binding
                                        plan
                                        ( \journal -> do
                                            prepared <-
                                                withLifecycleCursor
                                                    journal
                                                    frame
                                                    Authority.ProjectUp
                                                    Authority.Prepare
                                                    ( \prepareCursor -> do
                                                        executed <-
                                                            withExecuteLifecycleCursor
                                                                prepareCursor
                                                                (const (pure ()))
                                                        expectRight executed
                                                    )
                                            expectRight prepared
                                        )
                                expectRight journaled
                            )
                    framed
                )
        _ <- expectRight persisted
        readProtectedStoreImage (isolatedStoreRoot paths)

{- | Inspect the protected records from inside the suite body. At this point the
production command path must already have written one immutable revision-1
snapshot and bound the exact acquired run lease to those same digests.
-}
observeBoundHarnessPlan ::
    FilePath ->
    T.Text ->
    IO (Either String (T.Text, T.Text, T.Text, [ProtectedRecordImage]))
observeBoundHarnessPlan storeRoot projectName = do
    opened <- openProtectedStore storeRoot
    case opened of
        Left failure -> pure (Left (T.unpack (protectedErrorMessage failure)))
        Right store -> do
            entered <-
                tryProtectedEntry store $ \session ->
                    Right <$> inspect session
            pure $ case entered of
                Left failure -> Left (T.unpack (protectedErrorMessage failure))
                Right Nothing -> Left "the plan-binding transaction was still holding the protected entry"
                Right (Just result) -> result
  where
    inspect ::
        ProtectedSession session ->
        IO (Either String (T.Text, T.Text, T.Text, [ProtectedRecordImage]))
    inspect session = do
        listed <- listProtectedRecords session
        case listed of
            Left failure -> pure (Left (T.unpack (protectedErrorMessage failure)))
            Right keys -> do
                let leasePrefix = "lease." <> projectName <> "."
                    leaseKeys =
                        filter
                            ((leasePrefix `T.isPrefixOf`) . recordKeyText)
                            keys
                leases <- mapM (readLease session leasePrefix) leaseKeys
                case sequence leases of
                    Left failure -> pure (Left failure)
                    Right observed ->
                        case [bound | Just bound <- observed] of
                            [(runName, specDigest, planDigest)] -> do
                                snapshot <- inspectSnapshot session runName specDigest planDigest
                                image <- traverse (readImage session) keys
                                pure $ do
                                    (exactRun, exactSpec, exactPlan) <- snapshot
                                    exactImage <- sequence image
                                    Right (exactRun, exactSpec, exactPlan, exactImage)
                            other ->
                                pure
                                    ( Left
                                        ( "expected exactly one bound Harness lease, observed "
                                            ++ show other
                                        )
                                    )
    readImage ::
        ProtectedSession session ->
        RecordKey ->
        IO (Either String ProtectedRecordImage)
    readImage session key = do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (T.unpack (protectedErrorMessage failure))
            Right Nothing -> Left ("protected record disappeared: " ++ T.unpack (recordKeyText key))
            Right (Just record) ->
                Right
                    ( recordKeyText key
                    , recordVersionWord (protectedRecordVersion record)
                    , protectedRecordBytes record
                    )
    readLease ::
        ProtectedSession session ->
        T.Text ->
        RecordKey ->
        IO (Either String (Maybe (T.Text, T.Text, T.Text)))
    readLease session leasePrefix key = do
        observed <- readProtectedRecord session key
        pure $ case observed of
            Left failure -> Left (T.unpack (protectedErrorMessage failure))
            Right Nothing -> Left ("lease record disappeared: " ++ T.unpack (recordKeyText key))
            Right (Just record) -> case recordFields record of
                ["bound", _epoch, specDigest, planDigest] ->
                    Right
                        ( Just
                            ( T.drop (T.length leasePrefix) (recordKeyText key)
                            , specDigest
                            , planDigest
                            )
                        )
                _ -> Right Nothing
    {- Read the persisted snapshot back through the production snapshot-view
    decoder ('Mode.inspectPlanSnapshot') rather than re-parsing the record bytes here.
    The record is a versioned, length-framed wire, and a second hand-written
    parser in the test is exactly what drifts when that framing changes: this
    assertion previously split the payload on tabs and could no longer match any
    record the encoder writes. Going through the shipped decoder means the test
    observes what production observes, by construction. -}
    inspectSnapshot ::
        ProtectedSession session ->
        T.Text ->
        T.Text ->
        T.Text ->
        IO (Either String (T.Text, T.Text, T.Text))
    inspectSnapshot session runName specDigest planDigest =
        do
            admitted <-
                withInstalledProjectIdentity projectName $ \project -> do
                    inspected <- inspectPlanSnapshot session project runName
                    pure $ case inspected of
                        Left failure -> Left (T.unpack (modeErrorMessage failure))
                        Right snapshot
                            | planSnapshotViewRevision snapshot == 1
                            , planSnapshotViewSpecDigest snapshot == specDigest
                            , planSnapshotViewPlanDigest snapshot == planDigest ->
                                Right (runName, specDigest, planDigest)
                        Right snapshot ->
                            Left
                                ( "the bound lease and revision-1 snapshot disagree: "
                                    ++ show
                                        ( planSnapshotViewRevision snapshot
                                        , planSnapshotViewSpecDigest snapshot
                                        , planSnapshotViewPlanDigest snapshot
                                        )
                                )
            pure $ case admitted of
                Left failure -> Left (T.unpack (authorityErrorMessage failure))
                Right result -> result
    recordFields :: ProtectedRecord -> [T.Text]
    recordFields =
        map (T.pack . ByteStringChar8.unpack)
            . ByteStringChar8.split '\t'
            . protectedRecordBytes

-- | A stack-driven suite with a trivial bring-up and a single passing assertion.
passingSuite :: TestSuite
passingSuite =
    TestSuite
        (pure (Right ()))
        (\_ -> pure ())
        [Case (fixtureCaseId "ok") 1 False]
        (\_ _ -> pure Pass)
        (pure ())

-- | A stack-driven suite whose single case asserts a failure.
failingSuite :: TestSuite
failingSuite =
    TestSuite
        (pure (Right ()))
        (\_ -> pure ())
        [Case (fixtureCaseId "fails") 1 False]
        (\_ _ -> pure (Fail "seeded case failure"))
        (pure ())

-- | A suite with no cases (rejected by the project-spec validator).
emptySuiteFixture :: TestSuite
emptySuiteFixture =
    TestSuite (pure (Right ())) (\_ -> pure ()) [] (\_ _ -> pure Pass) (pure ())

fixtureCaseId :: T.Text -> CaseId
fixtureCaseId value = either (error . show) id (mkCaseId value)

{- | Write a fixture project config at the executable sibling path for a
gate-needing command, then remove it.
-}
withProjectConfig :: IO () -> IO ()
withProjectConfig action = do
    projectName <- executableProjectName
    path <- Schema.siblingProjectConfigPath projectName
    let cfg = Fixture.defaultProjectConfig projectName "." HostOrchestrator
    (Schema.writeProjectConfigFile Fixture.projectConfigCodec path cfg >> action) `finally` removeFile path

{- | A host-orchestrator config whose command classes have been widened with
@ServiceCommand@ *directly*, bypassing 'Context.addRole'.

Since § 15.9 'Context.addRole' refuses this pair outright, the only way such a
config exists is a hand-edited or forged @<project>.dhall@ — which is precisely
what this fixture models. The test it feeds proves the second line of defence:
even when the class is present, the leaf-placement gate still refuses
@service run@ on a non-leaf primary.
-}
withMultiRoleHostServiceConfig :: IO () -> IO ()
withMultiRoleHostServiceConfig action = do
    projectName <- executableProjectName
    let baseCfg = Fixture.defaultProjectConfig projectName "." HostOrchestrator
        forged =
            (Fixture.context baseCfg)
                { Context.allowedCommandClasses =
                    Context.allowedCommandClasses (Fixture.context baseCfg)
                        ++ [Context.ServiceCommand]
                , Context.capabilities =
                    Context.capabilities (Fixture.context baseCfg) ++ [Context.ServicePort]
                }
        cfg = baseCfg{Fixture.context = forged}
    path <- Schema.siblingProjectConfigPath projectName
    (Schema.writeProjectConfigFile Fixture.projectConfigCodec path cfg >> action) `finally` removeFile path

withServiceProjectConfig :: IO () -> IO ()
withServiceProjectConfig action = do
    projectName <- executableProjectName
    let witnessName = "HOSTBOOTSTRAP_CURRENT_FRAME"
        parentCfg = Fixture.defaultProjectConfig projectName "." HostOrchestrator
        cfg = parentCfg{Fixture.context = Context.deriveHostDaemonContext (Fixture.context parentCfg) "."}
        frame = T.unpack (Context.currentFrame (Fixture.context cfg))
    path <- Schema.siblingProjectConfigPath projectName
    previous <- lookupEnv witnessName
    let restore = do
            removeFile path
            maybe (unsetEnv witnessName) (setEnv witnessName) previous
    (Schema.writeProjectConfigFile Fixture.projectConfigCodec path cfg >> setEnv witnessName frame >> action) `finally` restore

schemaFixtureOutput :: String -> IO T.Text
schemaFixtureOutput fixture = do
    executable <- getExecutablePath
    (exitCode, output, err) <-
        readProcessWithExitCode executable ["--hostbootstrap-schema-fixture", fixture] ""
    case exitCode of
        ExitSuccess -> pure (T.pack output)
        _ -> assertFailure ("schema fixture " ++ fixture ++ " failed: " ++ err)

{- | Run one schema command in an isolated copy of this test executable. The
parent test captures this process's stdout, avoiding Tasty's own progress
renderer while still exercising the literal command parser and action.
-}
runSchemaFixture :: String -> IO ()
runSchemaFixture fixture = do
    projectName <- executableProjectName
    case fixture of
        "bare" ->
            withArgs ["context", "schema"] $
                CLI.runBareHostBootstrapCLI (T.unpack projectName)
        "consumer" -> do
            let budgetCodec = requireCodecWitness "CLISpec.Budget" (autoCodecWitness @V.Budget)
                arts = [artifactOf "localBudget" budgetCodec (V.Budget 1 2 3)]
            withArgs ["context", "schema"] $
                runHostBootstrapCLI (specWith passingSuite (pure ()) arts)
        "service" -> do
            let spec = specWithServices Nothing [("web", pure ())]
            withArgs ["service", "schema"] $
                runHostBootstrapCLI spec
        "project-dry-run" -> do
            marker <-
                lookupEnv "HOSTBOOTSTRAP_CLI_DRY_RUN_MARKER"
                    >>= maybe (die "missing dry-run effect marker") pure
            let probingChain :: FixtureFragment
                probingChain _ _ =
                    [ deployVMStep
                        "launch the VM"
                        (StepFrame "host-orchestrator-0" "metal")
                        (\_ -> writeFile marker "effect ran\n" >> pure StepChanged)
                    ]
                spec = finalized (addSteps probingChain (builderWith passingSuite (pure ()) []))
            withArgs ["project", "up", "--dry-run"] $
                runHostBootstrapCLI spec
        -- @--help@ prints to stdout and exits successfully, so the rendered
        -- surface text is captured the same way a schema snapshot is.
        "test-run-help" ->
            withArgs ["test", "run", "--help"] $
                runHostBootstrapCLI (specWith passingSuite (pure ()) [])
        _ -> die ("unknown schema fixture " ++ show fixture)

assertGolden :: FilePath -> T.Text -> IO ()
assertGolden name actual = do
    cwd <- getCurrentDirectory
    root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
    expected <- TIO.readFile (root </> "core" </> "hostbootstrap-core" </> "test" </> "golden" </> name)
    actual @?= expected

serviceSchemaOutline :: T.Text -> T.Text
serviceSchemaOutline =
    T.unlines
        . filter
            ( \line ->
                any
                    (`T.isInfixOf` line)
                    [ "service variants:"
                    , "  web"
                    , "-- full project schema"
                    , "service schema family"
                    , "- service:"
                    , "wire: ServiceRoleWire"
                    , "roleServiceFields"
                    ]
            )
        . T.lines
