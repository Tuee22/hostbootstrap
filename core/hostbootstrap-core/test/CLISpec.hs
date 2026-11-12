{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module CLISpec (readOnlyRecordsSupported, runIdentityMismatchProbe, runSchemaFixture, tests) where

import ActivationSpec (withBrokerFor)
import ConditionalCase (conditionalCase)
import Control.Exception (ErrorCall (ErrorCall), IOException, bracket, finally, throwIO, try)
import qualified Crypto.Hash as Hash
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Control.Monad (forM_, when)
import Data.List (isInfixOf, isPrefixOf, sort)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TIO
import Data.Word (Word64)
import Expect (expectRight)
import qualified Fixture
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import HostBootstrap.Activation (ActivationManifestInput (..), activationManifest, activationSecretDigestFromBytes, activationVerificationKeyBytes)
import HostBootstrap.Authority (
    AuthorityError (AuthorityInvalidIdentity),
    InstalledProjectIdentity,
    authorityErrorMessage,
    installedProjectName,
    normalizeExecutableIdentity,
    withInstalledProjectIdentity,
 )
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.CLI (
    ProjectSpec,
    ProjectSpecBuilder,
    ProjectSpecError (..),
    addArtifacts,
    addAssemblyInputs,
    addForwardChildPlan,
    addServices,
    addSteps,
    finalizeProjectSpec,
    projectArtifactNames,
    projectServiceVariantNames,
    projectSpec,
    projectStepPlan,
 )
import qualified HostBootstrap.CLI as CLI
import qualified Dhall
import HostBootstrap.Command (coreCommandNames)
import HostBootstrap.Config.Class (AssemblyRequest (..), ConfigAssembly, ExistingOutputPolicy (OverwriteExistingOutput), ProjectCfg (withHarnessProjectCodec, withProductionProjectCodec), configInput, projectCodecSpecDigest, pureConfigAssembly)
import HostBootstrap.Config.Fields (ScopeKind (ProductionScope), inspectLocalContext, localCurrentFrame, renderValidatedServiceRequest)
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Context (ContextKind (HostOrchestrator))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (ConfigArtifact, artifactName, artifactOf, autoCodecWitness, coreArtifacts, requireCodecWitness)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Harness (
    AssertionPhase (AfterRestart, BeforeRestart),
    Case (Case),
    CaseId,
    CaseLifecycle (AssertAcrossRestart, AssertOnce),
    CaseResult (Fail, Pass),
    SafetyRefusal (SafetyRefusal),
    TestSuite (TestSuite),
    allCasesSelector,
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
import HostBootstrap.Lift.Context (IncusVM (IncusVM), emptyVMStack, inVM, vmContext)
import HostBootstrap.ProjectPlan (
    PlanError (InvalidProjectPlan),
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
    mkRecordName,
    openProtectedStore,
    protectedErrorMessage,
    protectedStoreRoot,
    readProtectedRecord,
    recordKeyText,
    recordNameIdentity,
    recordTupleSeparator,
    recordVersionWord,
    tryProtectedEntry,
    withProtectedEntry,
    withRunLiveness,
 )
import HostBootstrap.RoleLifecycle (
    DeclaredEffects (NoEffects, WithEffect),
    EffectName (NetworkListenName),
    RoleAcquireOutcome (Acquired),
    RolePrereqOutcome (PrereqSatisfied),
    RoleProbeOutcome (ProbeReadyNow),
    RoleReleaseOutcome (Released),
    mkRoleResourceRequest,
    rolePlanDraft,
    rolePlanDraftDigest,
 )
import HostBootstrap.Service (
    ServiceRegistry,
    ServiceRegistryError (..),
    ServiceResourceBackend (..),
    emptyServiceRegistry,
    installServiceActivationRevision,
    serviceActivationRevisionPath,
    serviceId,
    serviceProgramDefinition,
    serviceRegistry,
    serviceRoleSchemaFamilies,
    withFinalizedServiceRegistry,
    withSelectedServiceProgram,
 )
import HostBootstrap.Service.Program (
    ServiceBackend (..),
    ServicePayloads (..),
    lookupAcquiredResource,
    serve,
    withReadyServiceHandles,
 )
import HostBootstrap.Step (ProjectStepId, ReversePolicy (PreserveOnReverse, ProjectManagedReverse), Step, StepFrame (..), StepObservation (..), StepPlanError (DuplicateStepIdentities, EmptyStepPlan), TeardownAction (DeleteFrame, StopFrame), TeardownOutcome (TeardownReleased), deployVMStep, descendsVia, projectStep, projectStepId, reversedBy, stepLabel, stepPlanSteps)
import SourceGuard (repoRelativePath)
import qualified SourceGuard
import System.Directory (Permissions (writable), createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getFileSize, doesPathExist, getCurrentDirectory, getPermissions, listDirectory, removeFile, setPermissions, withCurrentDirectory)
import System.Environment (getExecutablePath, lookupEnv, setEnv, unsetEnv, withArgs)
import qualified System.Environment.Blank as BlankEnvironment
import System.Exit (ExitCode (ExitFailure, ExitSuccess), die)
import System.FilePath (takeDirectory, (</>))
import System.Info (os)
import System.IO (SeekMode (AbsoluteSeek), hClose, hFlush, hGetLine, hSeek, openBinaryTempFile, stderr, stdout)
import System.IO.Temp (withSystemTempDirectory, withSystemTempFile)
import System.IO.Unsafe (unsafePerformIO)
import System.IO.Error (isPermissionError)
import System.Process (CreateProcess (std_in, std_out), StdStream (CreatePipe), createProcess, proc, readProcessWithExitCode, waitForProcess)
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

{- | A CLI fixture whose restricted Harness assembler retains the exact
canonical root selected by the surrounding runtime test.
-}
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
        HarnessAssembly _ _ _ _ ->
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
        , testCase "project specs reject duplicate test case ids exactly" $ do
            let duplicateId = fixtureCaseId "duplicate"
                suite =
                    TestSuite
                        (pure (Right ()))
                        (\_ _ -> pure ())
                        [Case duplicateId AssertOnce, Case duplicateId AssertOnce]
                        (\_ _ -> pure Pass)
                        (pure ())
            (() <$ finalizeProjectSpec (addSteps sampleChain (builderWith suite (pure ()) [])))
                @?= Left (DuplicateProjectCaseIds ["duplicate"])
        , testCase "project artifacts cannot shadow a genuine core artifact" $
            case coreArtifacts of
                coreArtifact : _ -> do
                    let builder =
                            addArtifacts [coreArtifact] $
                                addSteps sampleChain $
                                    builderWith passingSuite (pure ()) []
                    (() <$ finalizeProjectSpec builder)
                        @?= Left (CoreArtifactShadowing [T.unpack (artifactName coreArtifact)])
                [] -> assertFailure "the core artifact registry must supply the shadowing subject"
        , testCase "project specs reject duplicate project artifact names exactly" $ do
            let budgetCodec = requireCodecWitness "CLISpec.DuplicateBudget" (autoCodecWitness @V.Budget)
                firstArtifact = artifactOf "duplicate-project-artifact" budgetCodec (V.Budget 1 2 3)
                secondArtifact = artifactOf "duplicate-project-artifact" budgetCodec (V.Budget 2 3 4)
                builder =
                    addArtifacts [secondArtifact] $
                        addArtifacts [firstArtifact] $
                            addSteps sampleChain $
                                builderWith passingSuite (pure ()) []
            (() <$ finalizeProjectSpec builder)
                @?= Left (DuplicateProjectArtifacts ["duplicate-project-artifact"])
        , testCase "real project specs reject a missing forward-child projector" $
            case finalizeProjectSpec
                ( addSteps sampleChain $
                    builderWithoutForwardChildPlan
                        "/workspace/demo"
                        "cli"
                        passingSuite
                        (pure ())
                        []
                ) of
                Left MissingForwardChildPlan -> pure ()
                other -> assertFailure ("expected MissingForwardChildPlan, got " ++ either show (const "Right ProjectSpec") other)
        , testCase "one forward-child projector completes real project finalization" $
            case finalizeProjectSpec
                (addSteps sampleChain (builderWith passingSuite (pure ()) [])) of
                Right _ -> pure ()
                Left failure -> assertFailure ("expected one projector to finalize, got " ++ show failure)
        , testCase "duplicate forward-child projectors refuse instead of replacing" $
            case finalizeProjectSpec
                ( addSteps sampleChain $
                    addForwardChildPlan
                        Fixture.refusingForwardChildPlan
                        (builderWith passingSuite (pure ()) [])
                ) of
                Left DuplicateForwardChildPlan -> pure ()
                other -> assertFailure ("expected DuplicateForwardChildPlan, got " ++ either show (const "Right ProjectSpec") other)
        , testCase "runtime executable identity must match the declared project" $ do
            actualProject <- executableProjectName
            executable <- getExecutablePath
            (exitCode, _output, diagnostic) <-
                readProcessWithExitCode executable ["--hostbootstrap-cli-identity-mismatch-probe"] ""
            exitCode @?= ExitFailure 1
            let rendered = T.pack diagnostic
                declared = actualProject <> "-declared-mismatch"
            assertBool
                "the CLI reports the executable identity mismatch"
                ("does not match the invoked executable" `T.isInfixOf` rendered)
            assertBool
                "the refusal names the declared project"
                (("declared project name " <> declared) `T.isInfixOf` rendered)
            assertBool
                "the refusal names the actual invoked executable"
                (("invoked executable " <> actualProject) `T.isInfixOf` rendered)
        , testCase "runtime executable identity accepts the actual declared project" $ do
            actualProject <- executableProjectName
            result <-
                try
                    ( withArgs ["context", "path"] $
                        CLI.runHostBootstrapCLI
                            (T.unpack actualProject)
                            (specWith passingSuite (pure ()) [])
                    ) ::
                    IO (Either ExitCode ())
            result @?= Right ()
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
        , testCase "a config-dependent fragment that yields no step refuses concrete projection" $ do
            let fragment :: FixtureFragment
                fragment root cfg
                    | Fixture.cpu (Fixture.resources cfg) == 4 = []
                    | otherwise = sampleChain root cfg
            spec <- expectRight (finalizeProjectSpec (addSteps fragment (builderWith passingSuite (pure ()) [])))
            withProductionProjectCodec @Fixture.ProjectConfig @Fixture.FixtureProject $ \baseCodec ->
                withFinalizedProjectSpec
                    ProductionScope
                    baseCodec
                    emptyServiceRegistry
                    (projectStepPlan spec)
                    Fixture.refusingForwardChildPlan
                    ( \finalizedSpec ->
                        withSystemTempDirectory "hostbootstrap-cli-empty-fragment" $ \directory -> do
                            let value = Fixture.defaultProjectConfig "cli-empty-fragment" (T.pack directory) HostOrchestrator
                            Fixture.cpu (Fixture.resources value) @?= 4
                            rooted <-
                                withCanonicalProjectRoot (directory </> "fixture.dhall") directory $ \root -> do
                                    validated <-
                                        Schema.withValidatedConfig
                                            (finalizedProjectCodec finalizedSpec)
                                            value
                                            ( \_wire config ->
                                                (() <$ projectPlanDrafts finalizedSpec root config)
                                                    @?= Left (InvalidProjectPlan EmptyStepPlan)
                                            )
                                    either assertFailure pure validated
                                    nonempty <-
                                        expectRight $
                                            projectStepPlan spec root value{Fixture.resources = Fixture.Resources 5 "8GiB" "20GiB"}
                                    map stepLabel (NonEmpty.toList (stepPlanSteps nonempty)) @?= ["launch the VM"]
                            either (assertFailure . show) pure rooted
                    )
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
            map stepLabel (NonEmpty.toList (stepPlanSteps plan)) @?= ["first", "second"]
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
            map stepLabel (NonEmpty.toList (stepPlanSteps plan)) @?= ["launch the VM"]
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
        , testCase "test run fails fast without a test.dhall" $ withIsolatedHarnessState $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            stateRoot <- getCurrentDirectory
            -- No sibling project config and no test config: the documented first state.
            forM_ [cfgPath, testPath] $ \stale -> doesFileExist stale >>= \present -> when present (removeFile stale)
            let storeRoot = stateRoot </> ".hostbootstrap" </> "authority" </> T.unpack projectName
            before <- snapshotTree storeRoot
            (result, diagnostic) <-
                captureCLIExitStderr
                    (withArgs ["test", "run", "all"] (runHostBootstrapCLI (specWithHarnessContext stateRoot projectName passingSuite (pure ()) [])))
            result @?= Left (ExitFailure 1)
            assertBool
                ("the refusal names the missing test config, saw " ++ T.unpack diagnostic)
                (T.pack ("test run: missing " ++ testPath) `T.isInfixOf` diagnostic && T.pack "test init` first" `T.isInfixOf` diagnostic)
            snapshotTree storeRoot >>= (@?= before)
        , testCase "test init writes a test config without a pre-existing project config" $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            doesFileExist cfgPath >>= \present -> when present (removeFile cfgPath)
            doesFileExist cfgPath >>= (@?= False)
            ( do
                    result <-
                        try (withArgs ["test", "init"] (runHostBootstrapCLI (specWith passingSuite (pure ()) []))) ::
                            IO (Either ExitCode ())
                    result @?= Right ()
                    -- test init writes only the test config; it neither reads nor creates the sibling.
                    doesFileExist testPath >>= (@?= True)
                    doesFileExist cfgPath >>= (@?= False)
                )
                `finally` removeFile testPath
        , testCase "test init refuses an existing test config unless replacement is requested" $ do
            projectName <- executableProjectName
            testPath <- Schema.siblingTestConfigPath projectName
            let spec = specWith passingSuite (pure ()) []
                initWith args =
                    try (withArgs ("test" : "init" : args) (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                refusedInit = do
                    (result, diagnostic) <- captureCLIExitStderr (withArgs ["test", "init"] (runHostBootstrapCLI spec))
                    result @?= Left (ExitFailure 1)
                    assertBool
                        ("the refusal names the file and the flag, saw " ++ T.unpack diagnostic)
                        (T.pack (testPath ++ " already exists; pass --replace to overwrite it") `T.isInfixOf` diagnostic)
            ( do
                    first <- initWith []
                    first @?= Right ()
                    original <- TIO.readFile testPath
                    -- A second plain `init` must not silently replace what the
                    -- operator may have edited.
                    refusedInit
                    TIO.writeFile testPath (original <> "-- operator edit\n")
                    edited <- TIO.readFile testPath
                    refusedInit
                    TIO.readFile testPath >>= (@?= edited)
                    -- Explicit replacement is the only route that overwrites.
                    replaced <- initWith ["--replace"]
                    replaced @?= Right ()
                    TIO.readFile testPath >>= (@?= original)
                )
                `finally` removeFile testPath
        , testCase "test config writer resolves only the installed project's sibling" $ do
            projectName <- executableProjectName
            expected <- Schema.siblingTestConfigPath projectName
            executable <- getExecutablePath
            written <-
                withInstalledProjectIdentity projectName $ \project ->
                    Schema.testConfigWriteFor project Fixture.testConfigCodec (Fixture.defaultTestConfig (Fixture.Resources 4 "8GiB" "20GiB"))
            request <- either (assertFailure . show) pure written
            Schema.testConfigWritePath request @?= expected
            takeDirectory (Schema.testConfigWritePath request) @?= takeDirectory executable
            rejected <- withInstalledProjectIdentity "../escape" (\_ -> pure ())
            case rejected of
                Left (AuthorityInvalidIdentity _) -> pure ()
                other -> assertFailure ("an escaping name was not refused: " ++ show other)
        , testCase "test config replace leaves the prior file intact when rendering fails" $ do
            projectName <- executableProjectName
            testPath <- Schema.siblingTestConfigPath projectName
            let spec = specWith passingSuite (pure ()) []
                aborted = (Fixture.defaultTestConfig (Fixture.Resources 4 "8GiB" "20GiB")){Fixture.testResources = error "render aborted"}
            ( do
                    initialized <- try (withArgs ["test", "init"] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                    initialized @?= Right ()
                    original <- ByteString.readFile testPath
                    written <-
                        withInstalledProjectIdentity projectName $ \project ->
                            Schema.testConfigWriteFor project Fixture.testConfigCodec aborted
                    request <- either (assertFailure . show) pure written
                    thrown <- try (Schema.installTestConfig Schema.ReplaceExistingTestConfig request)
                    case thrown of
                        Left (ErrorCall message) -> message @?= "render aborted"
                        Right outcome -> assertFailure ("a failing render was published: " ++ show outcome)
                    ByteString.readFile testPath >>= (@?= original)
                    siblings <- listDirectory (takeDirectory testPath)
                    filter (".hostbootstrap-config.tmp" `isPrefixOf`) siblings @?= []
                )
                `finally` removeFile testPath
        , testCase "test config refuse creates nothing when rendering fails" $ do
            projectName <- executableProjectName
            testPath <- Schema.siblingTestConfigPath projectName
            doesFileExist testPath >>= \present -> when present (removeFile testPath)
            let aborted = (Fixture.defaultTestConfig (Fixture.Resources 4 "8GiB" "20GiB")){Fixture.testResources = error "render aborted"}
            written <-
                withInstalledProjectIdentity projectName $ \project ->
                    Schema.testConfigWriteFor project Fixture.testConfigCodec aborted
            request <- either (assertFailure . show) pure written
            thrown <- try (Schema.installTestConfig Schema.RefuseExistingTestConfig request)
            case thrown of
                Left (ErrorCall message) -> message @?= "render aborted"
                Right outcome -> assertFailure ("a failing render was published: " ++ show outcome)
            doesPathExist testPath >>= (@?= False)
            siblings <- listDirectory (takeDirectory testPath)
            filter (".hostbootstrap-config.tmp" `isPrefixOf`) siblings @?= []
        , testCase "test init then test run exits non-zero when a case fails (config is generated then removed)" $ withIsolatedHarnessState $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            stateRoot <- getCurrentDirectory
            presentWhileOpened <- newIORef ([] :: [Bool])
            assertions <- newIORef (0 :: Int)
            let observingSuite =
                    TestSuite
                        (pure (Right ()))
                        (\_ _ -> doesFileExist cfgPath >>= \present -> modifyIORef' presentWhileOpened (<> [present]))
                        [Case (fixtureCaseId "fails") AssertOnce]
                        (\_ _ -> modifyIORef' assertions (+ 1) >> pure (Fail "the case asserts a failure"))
                        (pure ())
                spec =
                    specWithHarnessContext
                        stateRoot
                        projectName
                        observingSuite
                        (pure ())
                        []
            ( do
                    initialized <- try (withArgs ["test", "init"] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                    initialized @?= Right ()
                    result <-
                        try (withArgs ["test", "run", "all"] (runHostBootstrapCLI spec)) ::
                            IO (Either ExitCode ())
                    result @?= Left (ExitFailure 1)
                    -- The generated config is present each time an assertion environment
                    -- opens (one per planned variant: default and alternate), the failing
                    -- assertion ran once per variant, and the config is gone afterwards.
                    readIORef presentWhileOpened >>= (@?= [True, True])
                    readIORef assertions >>= (@?= 2)
                    doesFileExist cfgPath >>= (@?= False)
                    -- No sidecar of any shape survives: ownership is the
                    -- protected record the run settles, not a lock directory
                    -- beside the config (the test-harness-and-run-ownership phase).
                    doesPathExist (cfgPath ++ ".hostbootstrap-test-owner") >>= (@?= False)
                )
                `finally` removeFile testPath
        , testCase "test run interprets one exact Harness plan through forward and reverse" $ withIsolatedHarnessState $ do
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
                        ( \_ _ -> do
                            generatedConfigPresent <- doesFileExist cfgPath
                            records <- observeBoundHarnessPlan storeRoot projectName
                            modifyIORef' observed (++ [(generatedConfigPresent, records)])
                            pure ()
                        )
                        [Case (fixtureCaseId "ok") AssertOnce]
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
                                        ("acquisition." <> fixtureRecordName projectName <> recordTupleSeparator <> fixtureRecordName runName <> recordTupleSeparator)
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
        , testCase "a restart-spanning Harness case rotates and rebinds the same run before its second assertion" $ withIsolatedHarnessState $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            stateRoot <- getCurrentDirectory
            forwardCalls <- newIORef (0 :: Int)
            reverseCalls <- newIORef (0 :: Int)
            openedPhases <- newIORef []
            assertedPhases <- newIORef []
            let frame = StepFrame "host-orchestrator-0" "metal"
                restartChain :: FixtureFragment
                restartChain _ _ =
                    [ reversedBy
                        (\_ _ -> modifyIORef' reverseCalls (+ 1) >> pure TeardownReleased)
                        ( projectStep
                            (fixtureProjectStepId "same-run-restart-probe")
                            ProjectManagedReverse
                            "record both same-run Harness invocations"
                            frame
                            (\_ -> modifyIORef' forwardCalls (+ 1) >> pure StepChanged)
                        )
                    ]
                suite =
                    TestSuite
                        (pure (Right ()))
                        (\phase _ -> modifyIORef' openedPhases (++ [phase]) >> pure phase)
                        [Case (fixtureCaseId "survives-restart") AssertAcrossRestart]
                        (\phase _ -> modifyIORef' assertedPhases (++ [phase]) >> pure Pass)
                        (pure ())
                spec =
                    finalized $
                        addSteps
                            restartChain
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
                    readIORef forwardCalls >>= (@?= 4)
                    readIORef reverseCalls >>= (@?= 4)
                    readIORef openedPhases
                        >>= (@?= [BeforeRestart, AfterRestart, BeforeRestart, AfterRestart])
                    readIORef assertedPhases
                        >>= (@?= [BeforeRestart, AfterRestart, BeforeRestart, AfterRestart])
                    doesFileExist cfgPath >>= (@?= False)
                )
                `finally` removeFile testPath
        , testCase "a true pre-effect Harness refusal skips reverse and admits the successor variant" $ withIsolatedHarnessState $ do
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
        , testCase "a late Harness refusal reverses each acquired variant exactly once" $ withIsolatedHarnessState $ do
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
                                    <> fixtureRecordName projectName
                                    <> recordTupleSeparator
                                    <> fixtureRecordName runName
                                    <> recordTupleSeparator <> "late-refusal"
                                )
                    store <-
                        openProtectedStore storeRoot
                            >>= either (assertFailure . T.unpack . protectedErrorMessage) pure
                    version <-
                        withProtectedEntry
                            store
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
                        (\_ _ -> pure ())
                        [Case (fixtureCaseId "ok") AssertOnce]
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
        , testCase "test run refuses to overwrite an existing sibling project config" $ withIsolatedHarnessState $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            stateRoot <- getCurrentDirectory
            opened <- newIORef False
            let suite =
                    TestSuite
                        (pure (Right ()))
                        (\_ _ -> writeIORef opened True)
                        [Case (fixtureCaseId "ok") AssertOnce]
                        (\_ _ -> pure Pass)
                        (pure ())
                -- A run that would otherwise succeed, so the refusal is the existing config.
                spec = specWithHarnessContext stateRoot projectName suite (pure ()) []
            ( do
                    initialized <- try (withArgs ["test", "init"] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                    initialized @?= Right ()
                    Schema.writeProjectConfigFile
                        Fixture.projectConfigCodec
                        cfgPath
                        (Fixture.defaultProjectConfig projectName "/workspace/demo" HostOrchestrator)
                    before <- ByteString.readFile cfgPath
                    (result, diagnostic) <- captureCLIExitOutput (withArgs ["test", "run", "all"] (runHostBootstrapCLI spec))
                    result @?= Left (ExitFailure 1)
                    assertBool
                        ("the refusal names the existing config, saw " ++ T.unpack diagnostic)
                        (T.pack ("a production config already exists at " ++ cfgPath ++ "; refusing to overwrite it") `T.isInfixOf` diagnostic)
                    ByteString.readFile cfgPath >>= (@?= before)
                    readIORef opened >>= (@?= False)
                )
                `finally` (removeFile testPath >> removeFile cfgPath)
        , testCase "context inspect and context show render the sibling composition and write nothing" $ withIsolatedHarnessState $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            stateRoot <- getCurrentDirectory
            let cfg = Fixture.defaultProjectConfig projectName "." HostOrchestrator
                spec = specWith passingSuite (pure ()) []
                expected = Context.renderComposition (Fixture.context cfg)
                -- The executable's own directory holds the binary, so its tree is compared by file size.
                siblingDirectory = takeDirectory cfgPath
                siblings = do
                    names <- sort <$> listDirectory siblingDirectory
                    traverse
                        ( \name -> do
                            isFile <- doesFileExist (siblingDirectory </> name)
                            size <- if isFile then getFileSize (siblingDirectory </> name) else pure (-1)
                            pure (name, size)
                        )
                        names
            ( do
                    Schema.writeProjectConfigFile Fixture.projectConfigCodec cfgPath cfg
                    siblingsBefore <- siblings
                    stateBefore <- snapshotTree (stateRoot </> ".hostbootstrap")
                    (inspected, inspectedOut) <- captureCLIExitStdout (withArgs ["context", "inspect"] (runHostBootstrapCLI spec))
                    (shown, shownOut) <- captureCLIExitStdout (withArgs ["context", "show", cfgPath] (runHostBootstrapCLI spec))
                    inspected @?= Right ()
                    shown @?= Right ()
                    -- In-process stdout also carries the test runner's progress line, so the
                    -- command's output is the exact rendering ending the capture, printed once.
                    forM_ [("context inspect", inspectedOut), ("context show", shownOut)] $ \(label, output) -> do
                        assertBool (label ++ " ends with the exact composition, saw " ++ T.unpack output) (T.pack expected `T.isSuffixOf` output)
                        T.count (T.pack expected) output @?= 1
                    siblings >>= (@?= siblingsBefore)
                    snapshotTree (stateRoot </> ".hostbootstrap") >>= (@?= stateBefore)
                )
                `finally` removeFile cfgPath
        , testCase "context refuses a service role wire before decoding it" $ withIsolatedHarnessState $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            stateRoot <- getCurrentDirectory
            let spec = specWith passingSuite (pure ()) []
                refusal = "holds a service role wire; context renders a full project config"
                expectRefusal arguments = do
                    before <- snapshotTree (stateRoot </> ".hostbootstrap")
                    (result, diagnostic) <- captureCLIExitStderr (withArgs arguments (runHostBootstrapCLI spec))
                    result @?= Left (ExitFailure 1)
                    assertBool ("the refusal names the role wire, saw " ++ T.unpack diagnostic) (refusal `T.isInfixOf` diagnostic)
                    assertBool ("no decoder ran, saw " ++ T.unpack diagnostic) (not ("failed to decode" `T.isInfixOf` diagnostic))
                    snapshotTree (stateRoot </> ".hostbootstrap") >>= (@?= before)
            withSystemTempDirectory "hostbootstrap-context-role-wire" $ \directory -> do
                let shown = directory </> "role.dhall"
                TIO.writeFile shown serviceRoleWireFixture
                expectRefusal ["context", "show", shown]
            ( do
                    TIO.writeFile cfgPath serviceRoleWireFixture
                    expectRefusal ["context", "inspect"]
                )
                `finally` removeFile cfgPath
        , testCase "context show renders a Harness-written fixture config and asserts no scope" $ withIsolatedHarnessState $ do
            stateRoot <- getCurrentDirectory
            Fixture.withFixtureHarnessAuthority $ \project authority ->
                withSystemTempDirectory "hostbootstrap-context-harness" $ \directory -> do
                    let file = directory </> "harness.dhall"
                        cfg = Fixture.defaultProjectConfig (installedProjectName project) "." HostOrchestrator
                    published <-
                        withHarnessProjectCodec @Fixture.ProjectConfig
                            (V.harnessConfigAuthority authority)
                            (\codec -> Schema.publishScopedProjectConfigFile OverwriteExistingOutput codec file cfg)
                    published @?= Schema.ConfigPublished
                    before <- snapshotTree (stateRoot </> ".hostbootstrap")
                    (result, output) <- captureCLIExitStdout (withArgs ["context", "show", file] (runHostBootstrapCLI (specWith passingSuite (pure ()) [])))
                    result @?= Right ()
                    -- Whichever scope's codec wrote the file, the Production reader renders its context.
                    assertBool
                        ("context show ends with the written config's composition, saw " ++ T.unpack output)
                        (T.pack (Context.renderComposition (Fixture.context cfg)) `T.isSuffixOf` output)
                    snapshotTree (stateRoot </> ".hostbootstrap") >>= (@?= before)
        , testCase "context show names the Production codec when a file does not decode" $ withIsolatedHarnessState $ do
            stateRoot <- getCurrentDirectory
            withSystemTempDirectory "hostbootstrap-context-undecodable" $ \directory -> do
                let file = directory </> "broken.dhall"
                TIO.writeFile file "{ notAProjectConfig = 1 }"
                before <- snapshotTree (stateRoot </> ".hostbootstrap")
                (result, diagnostic) <- captureCLIExitStderr (withArgs ["context", "show", file] (runHostBootstrapCLI (specWith passingSuite (pure ()) [])))
                result @?= Left (ExitFailure 1)
                assertBool
                    ("the refusal names the Production codec, saw " ++ T.unpack diagnostic)
                    (T.pack ("context: failed to decode " ++ file ++ " with the Production project codec: ") `T.isInfixOf` diagnostic)
                snapshotTree (stateRoot </> ".hostbootstrap") >>= (@?= before)
        , testCase "context inspect refuses a missing sibling config and writes nothing" $ withIsolatedHarnessState $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            stateRoot <- getCurrentDirectory
            present <- doesFileExist cfgPath
            when present (removeFile cfgPath)
            stateBefore <- snapshotTree (stateRoot </> ".hostbootstrap")
            (result, diagnostic) <- captureCLIExitStderr (withArgs ["context", "inspect"] (runHostBootstrapCLI (specWith passingSuite (pure ()) [])))
            result @?= Left (ExitFailure 1)
            assertBool
                ("the refusal names the missing config, saw " ++ T.unpack diagnostic)
                (T.pack ("context: no config at " ++ cfgPath) `T.isInfixOf` diagnostic)
            snapshotTree (stateRoot </> ".hostbootstrap") >>= (@?= stateBefore)
            doesFileExist cfgPath >>= (@?= False)
        , testCase "test init refuses an off-root invocation and writes nothing" $ withIsolatedHarnessState $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            let spec = specWith passingSuite (pure ()) []
            ( do
                    Schema.writeProjectConfigFile Fixture.projectConfigCodec cfgPath (offRootProjectConfig projectName)
                    (result, diagnostic) <- captureCLIExitStderr (withArgs ["test", "init"] (runHostBootstrapCLI spec))
                    result @?= Left (ExitFailure 1)
                    assertBool
                        ("the refusal names the current frame, saw " ++ T.unpack diagnostic)
                        ("test: refusing a non-root invocation: current frame " `T.isInfixOf` diagnostic)
                    doesFileExist testPath >>= (@?= False)
                )
                `finally` (removeFile cfgPath)
        , testCase "test run refuses an off-root invocation before any lifecycle read" $ withIsolatedHarnessState $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            stateRoot <- getCurrentDirectory
            opened <- newIORef False
            let suite =
                    TestSuite
                        (pure (Right ()))
                        (\_ _ -> writeIORef opened True)
                        [Case (fixtureCaseId "ok") AssertOnce]
                        (\_ _ -> pure Pass)
                        (pure ())
                spec = specWith suite (pure ()) []
            ( do
                    initialized <- try (withArgs ["test", "init"] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                    initialized @?= Right ()
                    Schema.writeProjectConfigFile Fixture.projectConfigCodec cfgPath (offRootProjectConfig projectName)
                    before <- snapshotTree (stateRoot </> ".hostbootstrap")
                    (result, diagnostic) <- captureCLIExitStderr (withArgs ["test", "run", "all"] (runHostBootstrapCLI spec))
                    result @?= Left (ExitFailure 1)
                    assertBool
                        ("the refusal names the current frame, saw " ++ T.unpack diagnostic)
                        ("test: refusing a non-root invocation: current frame " `T.isInfixOf` diagnostic)
                    snapshotTree (stateRoot </> ".hostbootstrap") >>= (@?= before)
                    readIORef opened >>= (@?= False)
                )
                `finally` (removeFile testPath >> removeFile cfgPath)
        , testCase "test init refuses an undecodable sibling config instead of treating it as root" $ withIsolatedHarnessState $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            ( do
                    writeFile cfgPath "not a dhall project config"
                    (result, diagnostic) <- captureCLIExitStderr (withArgs ["test", "init"] (runHostBootstrapCLI (specWith passingSuite (pure ()) [])))
                    result @?= Left (ExitFailure 1)
                    assertBool
                        ("the refusal names the undecodable config, saw " ++ T.unpack diagnostic)
                        (T.pack ("test: failed to decode " ++ cfgPath) `T.isInfixOf` diagnostic)
                    doesFileExist testPath >>= (@?= False)
                )
                `finally` (removeFile cfgPath)
        , testCase "test init admits the root frame and the absent config" $ withIsolatedHarnessState $ do
            projectName <- executableProjectName
            cfgPath <- Schema.siblingProjectConfigPath projectName
            testPath <- Schema.siblingTestConfigPath projectName
            let spec = specWith passingSuite (pure ()) []
            ( do
                    absent <- try (withArgs ["test", "init"] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                    absent @?= Right ()
                    Schema.writeProjectConfigFile Fixture.projectConfigCodec cfgPath (Fixture.defaultProjectConfig projectName "." HostOrchestrator)
                    rooted <- try (withArgs ["test", "init", "--replace"] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                    rooted @?= Right ()
                )
                `finally` (removeFile testPath >> removeFile cfgPath)
        , testCase "service schema lists variants without a config" $ do
            let spec = specWithServices Nothing [("web", pure ())]
            result <-
                try (withArgs ["service", "schema"] (runHostBootstrapCLI spec)) ::
                    IO (Either ExitCode ())
            result @?= Right ()
        , testCase "bare init refuses zero CPU without publishing config" $ bareBudgetRefusal ["--cpu", "0"]
        , testCase "bare init refuses malformed memory without publishing config" $ bareBudgetRefusal ["--memory", "many"]
        , testCase "bare init retains explicit cluster resources" $
            withSystemTempDirectory "hostbootstrap-bare-resources" $ \directory ->
                withCurrentDirectory directory $
                    withPreservedInitSiblings $ \projectName _ -> do
                        let output = directory </> "bare.dhall"
                        (result, _) <- captureCLIExitStderr $ withArgs ["project", "init", "--cpu", "3", "--memory", "3GiB", "--storage", "10GiB", "--output", output] $ CLI.runBareHostBootstrapCLI (T.unpack projectName)
                        result @?= Right ()
                        bytes <- ByteString.readFile output
                        resources <- Dhall.input Dhall.auto ("(" <> TextEncoding.decodeUtf8 bytes <> ").bareResources")
                        resources @?= Context.ResourceEnvelope 3 "3GiB" "10GiB"
        , testCase "bare context schema command output matches its exact snapshot" $ do
            output <- schemaFixtureOutput "bare"
            assertGolden "context_schema_core.txt" output
        , testCase "the bare init builder refuses an incompatible added role through die" $
            withSystemTempDirectory "hostbootstrap-bare-init-refusal" $ \directory ->
                withCurrentDirectory directory $
                    withPreservedInitSiblings $ \projectName before -> do
                        (result, diagnostic) <-
                            captureCLIExitStderr $
                                withArgs ["project", "init", "--also-role", "cluster-service"] $
                                    CLI.runBareHostBootstrapCLI (T.unpack projectName)
                        result @?= Left (ExitFailure 1)
                        diagnostic @?= "binary context: a HostOrchestrator placement may not acquire ClusterService authority\n"
                        listDirectory directory >>= (@?= [])
                        after <- traverse (snapshotInitFile . fst) before
                        assertBool "refused bare init changed an executable sibling or identity file" (after == before)
        , testCase "the bare init builder publishes a valid config at an explicit temporary output" $
            withSystemTempDirectory "hostbootstrap-bare-init-output" $ \directory ->
                withCurrentDirectory directory $
                    withPreservedInitSiblings $ \projectName before -> do
                        let output = directory </> "bare.dhall"
                        result <-
                            try
                                ( withArgs ["project", "init", "--output", output] $
                                    CLI.runBareHostBootstrapCLI (T.unpack projectName)
                                ) ::
                                IO (Either ExitCode ())
                        result @?= Right ()
                        bytes <- ByteString.readFile output
                        assertBool "successful bare init wrote an empty config" (not (ByteString.null bytes))
                        resources <- Dhall.input Dhall.auto ("(" <> TextEncoding.decodeUtf8 bytes <> ").bareResources")
                        resources @?= Context.ResourceEnvelope 2 "2GiB" "8GiB"
                        listDirectory directory >>= (@?= ["bare.dhall"])
                        after <- traverse (snapshotInitFile . fst) before
                        assertBool "alternate-output bare init changed an executable sibling or identity file" (after == before)
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
            -- The bare token `all` is a substring of `.dhall`, so pin the exact phrases.
            assertBool
                ("the help names the every-case selector, saw " ++ T.unpack output)
                (T.pack ("or `" ++ allCasesSelector ++ "` for every compiled case") `T.isInfixOf` output)
            assertBool
                ("the help names the whole-matrix selector, saw " ++ T.unpack output)
                (T.pack ("or `" ++ allCasesSelector ++ "` for the whole matrix") `T.isInfixOf` output)
            assertBool
                ("no surface text names a suite, saw " ++ T.unpack output)
                (not ("SUITE" `T.isInfixOf` output) && not ("suite" `T.isInfixOf` output))
        , testCase "test run refuses an unknown case by naming the compiled set" $ withIsolatedHarnessState $ do
            projectName <- executableProjectName
            testPath <- Schema.siblingTestConfigPath projectName
            opened <- newIORef False
            let suite =
                    TestSuite
                        (pure (Right ()))
                        (\_ _ -> writeIORef opened True)
                        [Case (fixtureCaseId "ok") AssertOnce]
                        (\_ _ -> pure Pass)
                        (pure ())
                spec = specWith suite (pure ()) []
            ( do
                    initialized <- try (withArgs ["test", "init"] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                    initialized @?= Right ()
                    (result, diagnostic) <- captureCLIExitStderr (withArgs ["test", "run", "no-such-case"] (runHostBootstrapCLI spec))
                    result @?= Left (ExitFailure 1)
                    assertBool
                        ("the refusal names the compiled set, saw " ++ T.unpack diagnostic)
                        ("unknown test case \"no-such-case\"; available: ok, all" `T.isInfixOf` diagnostic)
                    -- The refusal precedes any assertion environment.
                    readIORef opened >>= (@?= False)
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
        , testCase "service run verifies activation and dispatches exactly its signed program variant" $ do
            webRan <- newIORef False
            acceleratorRan <- newIORef False
            withVerifiedServiceRuntime "accelerator" [("web", writeIORef webRan True), ("accelerator", writeIORef acceleratorRan True)] $ \spec ->
                withArgs ["service", "run"] (runHostBootstrapCLI spec)
            readIORef webRan >>= (@?= False)
            readIORef acceleratorRan >>= (@?= True)
        , testCase "service run refuses an empty Kubernetes UID before revision files" $
            assertMeasuredServiceInstanceRefused
                [ ("HOSTBOOTSTRAP_POD_UID", Just "")
                , ("HOSTBOOTSTRAP_CONTAINER_RESTART_COUNT", Just "0")
                , ("HOSTBOOTSTRAP_SERVICE_INVOCATION_NONCE", Nothing)
                ]
                "service run: activation: the measured Kubernetes pod UID is empty\n"
        , testCase "service run refuses an empty host nonce before revision files" $
            assertMeasuredServiceInstanceRefused
                [ ("HOSTBOOTSTRAP_POD_UID", Nothing)
                , ("HOSTBOOTSTRAP_CONTAINER_RESTART_COUNT", Nothing)
                , ("HOSTBOOTSTRAP_SERVICE_INVOCATION_NONCE", Just "")
                ]
                "service run: activation: the measured host invocation nonce is empty\n"
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
                lease <- expectSingleRecord ("lease." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") image
                case recordImageFields lease of
                    ["unbound", epoch] ->
                        assertBool "the dry-run lease retains a positive broker epoch" (epoch /= "0")
                    fields -> assertFailure ("expected an unbound dry-run lease, observed " ++ show fields)
                assertRecordCount "snapshot." 0 image
                assertRecordCount "acquisition." 0 image
                assertRecordCount "cursor." 0 image
                assertRecordCount "invocation." 0 image
        , testCase "project down on a never-brought-up project names the absent Production mode, not a reverse intent" $
            withIsolatedProjectConfig $ \paths -> do
                let spec = finalized (builderWith passingSuite (pure ()) [])
                (result, diagnostic) <- captureCLIExitStderr (withArgs ["project", "down"] (runHostBootstrapCLI spec))
                result @?= Left (ExitFailure 1)
                assertBool ("the refusal names the absent Production mode: " <> T.unpack diagnostic) ("observed absent" `T.isInfixOf` diagnostic)
                assertBool "the refusal does not claim a reverse intent" (not ("reverse-root intent" `T.isInfixOf` diagnostic))
                image <- readProtectedStoreImage (isolatedStoreRoot paths)
                assertRecordCount "reverse-root." 0 image
        , testCase "project down reports a typed liveness failure while an in-process holder owns the lock file" $
            withIsolatedProjectConfig $ \paths -> do
                observed <- newIORef ([] :: [TeardownAction])
                let chain :: FixtureFragment
                    chain _ _ =
                        [ reversedBy
                            (\_ action -> modifyIORef' observed (action :) >> pure TeardownReleased)
                            (deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (\_ -> pure StepChanged))
                        ]
                    spec = finalized (addSteps chain (builderWith passingSuite (pure ()) []))
                    run verb = captureCLIExitStderr (withArgs ["project", verb] (runHostBootstrapCLI spec))
                _ <- run "up"
                before <- readProtectedStoreImage (isolatedStoreRoot paths)
                livenessName <- either (assertFailure . show) pure (mkRecordName (isolatedProjectName paths))
                store <- openProtectedStore (isolatedStoreRoot paths) >>= either (assertFailure . show) pure
                held <- withRunLiveness store livenessName $ run "down"
                (result, diagnostic) <- either (assertFailure . show) (maybe (assertFailure "the test holder was refused its own liveness") pure) held
                result @?= Left (ExitFailure 1)
                assertBool ("the refusal is the typed liveness failure naming the busy lock: " <> T.unpack diagnostic) ("SnapshotLivenessFailure" `T.isInfixOf` diagnostic && "take the run liveness lock" `T.isInfixOf` diagnostic)
                readIORef observed >>= (@?= [])
                readProtectedStoreImage (isolatedStoreRoot paths) >>= (@?= before)
        , testCase "project down reports contended liveness while a peer process holds the lock and writes no reverse-root row" $
            withIsolatedProjectConfig $ \paths -> do
                observed <- newIORef ([] :: [TeardownAction])
                let chain :: FixtureFragment
                    chain _ _ =
                        [ reversedBy
                            (\_ action -> modifyIORef' observed (action :) >> pure TeardownReleased)
                            (deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (\_ -> pure StepChanged))
                        ]
                    spec = finalized (addSteps chain (builderWith passingSuite (pure ()) []))
                    run verb = captureCLIExitStderr (withArgs ["project", verb] (runHostBootstrapCLI spec))
                _ <- run "up"
                before <- readProtectedStoreImage (isolatedStoreRoot paths)
                self <- getExecutablePath
                (Just peerInput, Just peerOutput, _, peer) <-
                    createProcess
                        (proc self ["--hostbootstrap-liveness-hold-probe", isolatedStoreRoot paths, T.unpack (isolatedProjectName paths)])
                            { std_in = CreatePipe
                            , std_out = CreatePipe
                            }
                (result, diagnostic) <-
                    ( do
                        announced <- hGetLine peerOutput
                        announced @?= "held"
                        run "down"
                    )
                        `finally` hClose peerInput
                _ <- waitForProcess peer
                result @?= Left (ExitFailure 1)
                assertBool ("the refusal is contended liveness: " <> T.unpack diagnostic) ("SnapshotLivenessContended" `T.isInfixOf` diagnostic)
                readIORef observed >>= (@?= [])
                readProtectedStoreImage (isolatedStoreRoot paths) >>= (@?= before)
        , testCase "project down reports a liveness store failure and writes no reverse-root row" $
            withIsolatedProjectConfig $ \paths -> do
                observed <- newIORef ([] :: [TeardownAction])
                let chain :: FixtureFragment
                    chain _ _ =
                        [ reversedBy
                            (\_ action -> modifyIORef' observed (action :) >> pure TeardownReleased)
                            (deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (\_ -> pure StepChanged))
                        ]
                    spec = finalized (addSteps chain (builderWith passingSuite (pure ()) []))
                    run verb = captureCLIExitStderr (withArgs ["project", verb] (runHostBootstrapCLI spec))
                _ <- run "up"
                before <- readProtectedStoreImage (isolatedStoreRoot paths)
                livenessName <- either (assertFailure . show) pure (mkRecordName (isolatedProjectName paths))
                -- A directory where the lock file belongs cannot be opened as a lock.
                createDirectoryIfMissing True (isolatedStoreRoot paths </> "liveness" </> T.unpack livenessName <> ".lock")
                (result, diagnostic) <- run "down"
                result @?= Left (ExitFailure 1)
                assertBool ("the refusal is the liveness store failure: " <> T.unpack diagnostic) ("SnapshotLivenessFailure" `T.isInfixOf` diagnostic)
                readIORef observed >>= (@?= [])
                readProtectedStoreImage (isolatedStoreRoot paths) >>= (@?= before)
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
                        snapshot <- expectSingleRecord ("snapshot." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") image
                        assertBool "the exact snapshot is present before the effect" (not (ByteString.null (let (_, _, bytes) = snapshot in bytes)))
                        lease <- expectSingleRecord ("lease." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") image
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
                        lease <- expectSingleRecord ("lease." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") image
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
                lease <- expectSingleRecord ("lease." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") before
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
                            (vmContext (inVM (IncusVM "fixture-vm" "images:ubuntu/24.04") emptyVMStack))
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
                            (vmContext (inVM (IncusVM "fixture-vm" "images:ubuntu/24.04") emptyVMStack))
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
                        lease <- expectSingleRecord ("lease." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") image
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
                leaseBefore <- expectSingleRecord ("lease." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") before
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
                snapshotAfter <- expectSingleRecord ("snapshot." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") after
                snapshotAfter @?= snapshotBefore
                leaseAfter <- expectSingleRecord ("lease." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") after
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
                snapshotBefore <- expectSingleRecord ("snapshot." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") before
                leaseBefore <- expectSingleRecord ("lease." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") before
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
                expectSingleRecord ("snapshot." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") after >>= (@?= snapshotBefore)
                expectSingleRecord ("lease." <> fixtureRecordName (isolatedProjectName paths) <> recordTupleSeparator <> "production") after >>= (@?= leaseBefore)
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
          testCase "project down then destroy runs each declared reverse without reacquiring" $
            withIsolatedProjectConfig $ \paths -> do
                observed <- newIORef ([] :: [TeardownAction])
                acquired <- newIORef (0 :: Int)
                let reversedChain :: FixtureFragment
                    reversedChain _ _ =
                        [ reversedBy
                            (\_ action -> modifyIORef' observed (action :) >> pure TeardownReleased)
                            (deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (\_ -> modifyIORef' acquired (+ 1) >> pure StepChanged))
                        ]
                    spec = finalized (addSteps reversedChain (builderWith passingSuite (pure ()) []))
                prepared <-
                    try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                prepared @?= Right ()
                result <-
                    try (withArgs ["project", "down"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef observed >>= (@?= [StopFrame])
                downState <- readProtectedStoreImage (isolatedStoreRoot paths)
                (_, downVersion, _) <- expectSingleRecord "reverse-root." downState
                downVersion @?= 3
                repeatedDown <- try (withArgs ["project", "down"] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                repeatedDown @?= Right ()
                readIORef observed >>= (@?= [StopFrame])
                destroyed <-
                    try (withArgs ["project", "destroy"] (runHostBootstrapCLI spec)) ::
                        IO (Either ExitCode ())
                destroyed @?= Right ()
                readIORef observed >>= (@?= [DeleteFrame, StopFrame])
                readIORef acquired >>= (@?= 1)
                finalState <- readProtectedStoreImage (isolatedStoreRoot paths)
                (_, destroyVersion, _) <- expectSingleRecord "reverse-root." finalState
                destroyVersion @?= 6
                assertRecordCount "mode." 0 finalState
                repeatedDestroy <- try (withArgs ["project", "destroy"] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                repeatedDestroy @?= Right ()
                readIORef observed >>= (@?= [DeleteFrame, StopFrame])
                restarted <- try (withArgs ["project", "up"] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                restarted @?= Right ()
                readIORef acquired >>= (@?= 2)
                try (withArgs ["project", "destroy"] (runHostBootstrapCLI spec)) >>= (@?= (Right () :: Either ExitCode ()))
        , testCase "project down after a terminal destroy reports the terminal outcome without an effect" $
            withIsolatedProjectConfig $ \paths -> do
                observed <- newIORef ([] :: [TeardownAction])
                let chain :: FixtureFragment
                    chain _ _ =
                        [ reversedBy
                            (\_ action -> modifyIORef' observed (action :) >> pure TeardownReleased)
                            (deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (\_ -> pure StepChanged))
                        ]
                    spec = finalized (addSteps chain (builderWith passingSuite (pure ()) []))
                    run verb = try (withArgs ["project", verb] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                run "up" >>= (@?= Right ())
                run "destroy" >>= (@?= Right ())
                effects <- readIORef observed
                destroyed <- readProtectedStoreImage (isolatedStoreRoot paths)
                (_, destroyVersion, _) <- expectSingleRecord "reverse-root." destroyed
                destroyVersion @?= 3
                run "down" >>= (@?= Right ())
                readIORef observed >>= (@?= effects)
                readProtectedStoreImage (isolatedStoreRoot paths) >>= (@?= destroyed)
        , testCase "a repeated destroy refuses a recreated Production mode after its terminal closure" $
            withIsolatedProjectConfig $ \paths -> do
                destroyed <- newIORef (0 :: Int)
                let chain :: FixtureFragment
                    chain _ _ =
                        [ reversedBy
                            (\_ action -> (case action of DeleteFrame -> modifyIORef' destroyed (+ 1); _ -> pure ()) >> pure TeardownReleased)
                            (deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (\_ -> pure StepChanged))
                        ]
                    spec = finalized (addSteps chain (builderWith passingSuite (pure ()) []))
                    run verb = try (withArgs ["project", verb] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                run "up" >>= (@?= Right ())
                run "destroy" >>= (@?= Right ())
                readIORef destroyed >>= (@?= 1)
                encodedProject <- either (assertFailure . show) pure (mkRecordName (isolatedProjectName paths))
                modeKey <- either (assertFailure . show) pure (mkRecordKey ("mode." <> encodedProject))
                store <- openProtectedStore (isolatedStoreRoot paths) >>= either (assertFailure . show) pure
                -- The terminal receipt requires an absent mode; a live one means the
                -- closure it records is no longer the current state.
                written <- withProtectedEntry store $ \session ->
                    compareAndSwapProtectedRecord session modeKey ExpectAbsent "production\t1"
                either (assertFailure . show) (const (pure ())) written
                before <- readProtectedStoreImage (isolatedStoreRoot paths)
                run "destroy" >>= (@?= Left (ExitFailure 1))
                readIORef destroyed >>= (@?= 1)
                readProtectedStoreImage (isolatedStoreRoot paths) >>= (@?= before)
        , testCase "Destroy resumes the retained Pending continuation after Down" $
            withIsolatedProjectConfig $ \paths -> do
                acquired <- newIORef (0 :: Int)
                destroyed <- newIORef (0 :: Int)
                let chain :: FixtureFragment
                    chain _ _ =
                        [ reversedBy
                            ( \_ action -> do
                                case action of
                                    DeleteFrame -> modifyIORef' destroyed (+ 1)
                                    _ -> pure ()
                                pure TeardownReleased
                            )
                            (deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (\_ -> modifyIORef' acquired (+ 1) >> pure StepChanged))
                        ]
                    spec = finalized (addSteps chain (builderWith passingSuite (pure ()) []))
                    run verb = try (withArgs ["project", verb] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                run "up" >>= (@?= Right ())
                run "down" >>= (@?= Right ())
                image <- readProtectedStoreImage (isolatedStoreRoot paths)
                (keyText, version, bytes) <- expectSingleRecord "reverse-root." image
                version @?= 3
                pending <- pendingDestroyAfterDown bytes
                key <- either (assertFailure . show) pure (mkRecordKey keyText)
                store <- openProtectedStore (isolatedStoreRoot paths) >>= either (assertFailure . show) pure
                written <- withProtectedEntry store $ \session -> do
                    found <- readProtectedRecord session key >>= either (assertFailure . show) pure
                    record <- maybe (assertFailure "terminal Down disappeared") pure found
                    compareAndSwapProtectedRecord session key (ExpectVersion (protectedRecordVersion record)) pending
                either (assertFailure . show) (\v -> recordVersionWord v @?= 4) written
                run "destroy" >>= (@?= Right ())
                readIORef acquired >>= (@?= 1)
                readIORef destroyed >>= (@?= 1)
                terminal <- readProtectedStoreImage (isolatedStoreRoot paths)
                (_, terminalVersion, _) <- expectSingleRecord "reverse-root." terminal
                terminalVersion @?= 6
                run "destroy" >>= (@?= Right ())
                readIORef destroyed >>= (@?= 1)
                readProtectedStoreImage (isolatedStoreRoot paths) >>= (@?= terminal)
        , testCase "project down refuses while a Destroy Pending intent is retained, leaving the store unchanged" $
            withIsolatedProjectConfig $ \paths -> do
                effects <- newIORef (0 :: Int)
                let chain :: FixtureFragment
                    chain _ _ =
                        [ reversedBy
                            (\_ _ -> modifyIORef' effects (+ 1) >> pure TeardownReleased)
                            (deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (\_ -> pure StepChanged))
                        ]
                    spec = finalized (addSteps chain (builderWith passingSuite (pure ()) []))
                    run verb = captureCLIExitStderr (withArgs ["project", verb] (runHostBootstrapCLI spec))
                _ <- run "up"
                _ <- run "down"
                readIORef effects >>= (@?= 1)
                image <- readProtectedStoreImage (isolatedStoreRoot paths)
                (keyText, _, bytes) <- expectSingleRecord "reverse-root." image
                pending <- pendingDestroyAfterDown bytes
                key <- either (assertFailure . show) pure (mkRecordKey keyText)
                store <- openProtectedStore (isolatedStoreRoot paths) >>= either (assertFailure . show) pure
                written <- withProtectedEntry store $ \session -> do
                    found <- readProtectedRecord session key >>= either (assertFailure . show) pure
                    record <- maybe (assertFailure "terminal Down disappeared") pure found
                    compareAndSwapProtectedRecord session key (ExpectVersion (protectedRecordVersion record)) pending
                either (assertFailure . show) (const (pure ())) written
                before <- readProtectedStoreImage (isolatedStoreRoot paths)
                (result, diagnostic) <- run "down"
                result @?= Left (ExitFailure 1)
                assertBool
                    ("the refusal names the retained reverse-root intent: " <> T.unpack diagnostic)
                    ("a durable reverse-root intent owns ordinary lifecycle admission" `T.isInfixOf` diagnostic)
                readIORef effects >>= (@?= 1)
                readProtectedStoreImage (isolatedStoreRoot paths) >>= (@?= before)
        , testCase "project destroy on a never-brought-up project names the absent Production mode" $
            withIsolatedProjectConfig $ \paths -> do
                let spec = finalized (builderWith passingSuite (pure ()) [])
                (result, diagnostic) <- captureCLIExitStderr (withArgs ["project", "destroy"] (runHostBootstrapCLI spec))
                result @?= Left (ExitFailure 1)
                assertBool ("the refusal names the absent Production mode: " <> T.unpack diagnostic) ("observed absent" `T.isInfixOf` diagnostic)
                image <- readProtectedStoreImage (isolatedStoreRoot paths)
                assertRecordCount "reverse-root." 0 image
        , testGroup "Destroy after Down refuses stale predecessor evidence" $
            [ testCase (T.unpack prefix) $
                withIsolatedProjectConfig $ \paths -> do
                    destroyed <- newIORef (0 :: Int)
                    let chain :: FixtureFragment
                        chain _ _ =
                            [ reversedBy
                                ( \_ action -> do
                                    case action of
                                        DeleteFrame -> modifyIORef' destroyed (+ 1)
                                        _ -> pure ()
                                    pure TeardownReleased
                                )
                                (deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (\_ -> pure StepChanged))
                            ]
                        spec = finalized (addSteps chain (builderWith passingSuite (pure ()) []))
                        run verb = try (withArgs ["project", verb] (runHostBootstrapCLI spec)) :: IO (Either ExitCode ())
                    run "up" >>= (@?= Right ())
                    run "down" >>= (@?= Right ())
                    image <- readProtectedStoreImage (isolatedStoreRoot paths)
                    (keyText, _, _) <- case recordsWithPrefix prefix image of
                        record : _ -> pure record
                        [] -> assertFailure ("missing predecessor " ++ T.unpack prefix)
                    key <- either (assertFailure . show) pure (mkRecordKey keyText)
                    store <- openProtectedStore (isolatedStoreRoot paths) >>= either (assertFailure . show) pure
                    changed <- withProtectedEntry store $ \session -> do
                        found <- readProtectedRecord session key >>= either (assertFailure . show) pure
                        record <- maybe (assertFailure "predecessor disappeared") pure found
                        compareAndSwapProtectedRecord session key (ExpectVersion (protectedRecordVersion record)) (protectedRecordBytes record)
                    _ <- either (assertFailure . show) pure changed
                    before <- readProtectedStoreImage (isolatedStoreRoot paths)
                    run "destroy" >>= (@?= Left (ExitFailure 1))
                    readIORef destroyed >>= (@?= 0)
                    after <- readProtectedStoreImage (isolatedStoreRoot paths)
                    recordsWithPrefix "reverse-root." after @?= recordsWithPrefix "reverse-root." before
                    recordsWithPrefix "mode." after @?= recordsWithPrefix "mode." before
                    recordsWithPrefix "lease." after @?= recordsWithPrefix "lease." before
            | prefix <- ["reverse-root.", "mode.", "lease.", "acquisition.", "cursor."]
            ]
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
            description <- SourceGuard.readPackageDescription
            commandPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Command"
            entryPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Command.LifecycleEntry"
            reconcilePath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Reconcile"
            teardownPath <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Teardown"
            commandSource <- TIO.readFile commandPath
            entrySource <- TIO.readFile entryPath
            reconcileSource <- TIO.readFile reconcilePath
            teardownSource <- TIO.readFile teardownPath
            mainLibrary <- maybe (assertFailure "main library stanza missing") pure (SourceGuard.mainLibraryStanza description)
            mainComponent <- case [component | component <- SourceGuard.componentStanzas description, SourceGuard.componentHeader component == "library"] of
                [component] -> pure component
                _ -> assertFailure "main library component is missing or ambiguous"
            sources <- concat <$> traverse (SourceGuard.listHaskellSources . (packageRoot </>)) (SourceGuard.componentSourceDirs mainComponent)
            sourceContents <- traverse (\path -> (,) path <$> readFile path) sources
            let entryImporters = [path | (path, body) <- sourceContents, SourceGuard.importsModule "HostBootstrap.Command.LifecycleEntry" body]
            assertBool "qualified imports count as lifecycle entry imports" $
                SourceGuard.importsModule "HostBootstrap.Command.LifecycleEntry" "import qualified HostBootstrap.Command.LifecycleEntry as E"
            assertBool "commented imports do not count" $
                not (SourceGuard.importsModule "HostBootstrap.Command.LifecycleEntry" "-- import HostBootstrap.Command.LifecycleEntry")
            productionTokens <- concat <$> traverse
                (\name -> either assertFailure pure (SourceGuard.haskellDefinitionTokens name (T.unpack commandSource)))
                ["projectCommandGroup", "runExactProjectUp", "runExactHarnessDestroyProjection"]
            let entryTokens = SourceGuard.haskellTokens (T.unpack entrySource)
                contains fragment tokens = SourceGuard.haskellTokens (T.unpack fragment) `isInfixOf` tokens
                require fragment =
                    assertBool
                        ("Production command lost its exact route: " ++ T.unpack fragment)
                        (contains fragment productionTokens)
                forbid label source fragment =
                    assertBool
                        (label ++ " still contains compatibility shape " ++ T.unpack fragment)
                        (not (contains fragment (SourceGuard.haskellTokens (T.unpack source))))
                count fragment = SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens fragment) (unwords productionTokens)
            sort (map (repoRelativePath packageRoot) entryImporters)
                @?= ["src/HostBootstrap/Command.hs"]
            assertBool "the lifecycle entry must be a main-library other-module" $
                "HostBootstrap.Command.LifecycleEntry" `elem` SourceGuard.fieldModules "other-modules" mainLibrary
            mapM_
                (\component -> assertBool "the lifecycle entry must never be exposed" $
                    "HostBootstrap.Command.LifecycleEntry" `notElem` SourceGuard.fieldModules "exposed-modules" (SourceGuard.componentBody component))
                (SourceGuard.componentStanzas description)
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
                , "withRootProjectUpLifecycleEntry exactSpec rootAuthority Authority.ProjectUp verified bound binding lease plan lifecycleContext project (runRootProjectUpLifecycleEntry cfg self handoffScope loadSigningKey loadActivationSigningKey runFailedLocal)"
                , "withBoundProjectDestroyLifecycleEntry exactSpec rootAuthority verified bound binding lease plan lifecycleContext project ( \\entry current -> runRootProjectReverseLifecycleEntry"
                ]
            mapM_
                ( \fragment ->
                    assertBool
                        ("hidden lifecycle entry lost its exact route: " ++ T.unpack fragment)
                        (contains fragment entryTokens)
                )
                [ "withValidatedRootLifecycleContext"
                , "teardownPlan plan current verb"
                , "withAcquisitionJournal"
                , "withCurrentLifecycleCursor journal frame verb"
                , "withRootedPlanCatalogKernel finalized rootAuthority plan current lifecycleContext"
                , "settleRootedPlanCatalog store catalog"
                , "compareAndSwapProtectedRecord session key ExpectAbsent manifest"
                , "rootedPlanCatalogManifestMatchesKernel catalog (protectedRecordBytes record)"
                , "ProjectAuthority.authorizeRootProject rootAuthority verb verified bound binding lease plan journal executeCursor lifecycleContext project"
                , "ProjectAuthority.authorizeRootProject rootAuthority ProjectDestroy verified bound binding lease plan journal teardownCursor lifecycleContext project"
                , "runChainFromFrameWithDescentFailure cfg self store plan authority cursor"
                , "withTeardownLifecycleCursor cursor"
                ]
            count "withProjectPlan profile root validated drafts" @?= 1
            count "withRecoveredProductionProjectPlan profile root verified bound binding recoveredConfig recoveredDrafts" @?= 1
            count "withRootProjectUpLifecycleEntry" @?= 1
            mapM_
                (\fragment -> assertBool ("Production command retains compatibility shape " ++ T.unpack fragment) (not (contains fragment productionTokens)))
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
            assertBool "Command must import the public Chain facade" (SourceGuard.importsModule "HostBootstrap.Chain" (T.unpack commandSource))
            forbid "Command" commandSource "HostBootstrap.Chain.Compatibility"
            forbid "Reconcile" reconcileSource "compatibilityStepExecutionFor"
            forbid "Teardown" teardownSource "withCompatibilityTeardownPlan"
            forbid "Teardown" teardownSource "compatibilityReverseStepFor"
            mapM_
                (\component -> assertBool "Cabal retains the Chain compatibility module" $
                    "HostBootstrap.Chain.Compatibility" `notElem` concatMap (\field -> SourceGuard.fieldModules field (SourceGuard.componentBody component)) ["exposed-modules", "other-modules", "reexported-modules"])
                (SourceGuard.componentStanzas description)
            doesFileExist (sourceRoot </> "Chain" </> "Compatibility.hs") >>= (@?= False)
        , testGroup
            "operator refusal precedes lifecycle work"
            [ conditionalCase ["CLISpec", "operator refusal precedes lifecycle work"] readOnlyRecordsSupported verb
                ( withIsolatedProjectConfig $ \paths -> do
                    effects <- newIORef (0 :: Int)
                    let chain :: FixtureFragment
                        chain _ _ =
                            [ reversedBy
                                (\_ _ -> modifyIORef' effects (+ 1) >> pure TeardownReleased)
                                (deployVMStep "count effects" (StepFrame "host-orchestrator-0" "metal") (\_ -> modifyIORef' effects (+ 1) >> pure StepChanged))
                            ]
                        spec = finalized (addSteps chain (builderWith passingSuite (pure ()) []))
                        run action = captureCLIExitStderr $ withArgs ["project", action] (runHostBootstrapCLI spec)
                    if verb == "up" then pure () else fst <$> run "up" >>= (@?= Right ())
                    before <- readProtectedStoreImage (isolatedStoreRoot paths)
                    countBefore <- readIORef effects
                    let records = isolatedStoreRoot paths </> "records"
                    permissions <- getPermissions records
                    (result, diagnostic) <-
                        bracket
                            (setPermissions records permissions{writable = False})
                            (const (setPermissions records permissions))
                            (const (run verb))
                    result @?= Left (ExitFailure 1)
                    assertBool ("reports operator authorization refusal: " ++ T.unpack diagnostic) ("operator authorization refused:" `T.isInfixOf` diagnostic)
                    readProtectedStoreImage (isolatedStoreRoot paths) >>= (@?= before)
                    readIORef effects >>= (@?= countBefore)
                )
                (probeReadOnlyRecords >>= (@?= False))
            | verb <- ["up", "down", "destroy"]
            ]
        , testCase "parentless VM orchestrator cannot enter project up or down" $
            withIsolatedProjectConfig $ \paths -> do
                let config =
                        Fixture.defaultProjectConfig
                            (isolatedProjectName paths)
                            (T.pack (isolatedCanonicalRoot paths))
                            Context.VMOrchestrator
                    run verb =
                        captureCLIExitStderr $
                            withArgs ["project", verb] (runHostBootstrapCLI (specWith passingSuite (pure ()) []))
                Schema.writeProjectConfigFile Fixture.projectConfigCodec (isolatedConfigPath paths) config
                (upResult, upDiagnostic) <- run "up"
                (downResult, downDiagnostic) <- run "down"
                upResult @?= Left (ExitFailure 1)
                downResult @?= Left (ExitFailure 1)
                upDiagnostic @?= downDiagnostic
                assertBool "refusal identifies the host orchestrator command" ("HostOrchestratorCommand" `T.isInfixOf` upDiagnostic)
                doesPathExist (isolatedStoreRoot paths) >>= (@?= False)
        , testGroup
            "child frame refuses operator entry"
            [ testCase verb $
                withIsolatedProjectConfig $ \paths -> do
                    let root = T.pack (isolatedCanonicalRoot paths)
                        parent = Fixture.defaultProjectConfig (isolatedProjectName paths) root HostOrchestrator
                    child <- either assertFailure pure (Fixture.deriveProjectConfigForKind Context.VMOrchestrator parent root)
                    Schema.writeProjectConfigFile Fixture.projectConfigCodec (isolatedConfigPath paths) child
                    (result, diagnostic) <-
                        captureCLIExitStderr $
                            withArgs ["project", verb] (runHostBootstrapCLI (specWith passingSuite (pure ()) []))
                    result @?= Left (ExitFailure 1)
                    assertBool "context gate refuses the operator command" ("HostOrchestratorCommand" `T.isInfixOf` diagnostic)
                    doesPathExist (isolatedStoreRoot paths) >>= (@?= False)
            | verb <- ["up", "down", "destroy"]
            ]
        , testCase "project up fails fast without a sibling context" $
            withPreservedInitSiblings $ \projectName _ -> do
                cfgPath <- Schema.siblingProjectConfigPath projectName
                present <- doesFileExist cfgPath
                if present then removeFile cfgPath else pure ()
                doesFileExist cfgPath >>= (@?= False)
                (result, diagnostic) <-
                    captureCLIExitStderr $
                        withArgs ["project", "up", "--dry-run"] (runHostBootstrapCLI (specWith passingSuite (pure ()) []))
                result @?= Left (ExitFailure 1)
                assertBool "reports the missing sibling configuration" (T.pack ("missing " ++ cfgPath) `T.isInfixOf` diagnostic)
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
            [ serviceProgramDefinition
                (either error id (serviceId name))
                (\_ -> Right (if selected == Just name then Just () else Nothing))
                -- The fixture declares a listen-only row: enough that the
                -- selection carries a real declaration, narrow enough that a
                -- widening would show up as a diff here.
                (WithEffect NetworkListenName NoEffects)
                cliServiceResources
                cliServiceBackend
                ( \_ -> withReadyServiceHandles $ \ready -> case lookupAcquiredResource ready "listener" of
                    Nothing -> pure ()
                    Just listener -> serve [(listener, handler)]
                )
            | (name, handler) <- handlers
            ]

data CliServicePayloads

instance ServicePayloads CliServicePayloads where
    type ListenApp CliServicePayloads = IO ()
    type CallRequest CliServicePayloads = ()
    type CallReply CliServicePayloads = ()
    type WorkRequest CliServicePayloads = ()
    type WorkReply CliServicePayloads = ()

withVerifiedServiceRuntime ::
    String ->
    [(String, IO ())] ->
    (ProjectSpec Fixture.ProjectConfig Fixture.TestConfig -> IO ()) ->
    IO ()
withVerifiedServiceRuntime selected handlers use =
    withSystemTempDirectory "hostbootstrap-cli-service-runtime" $ \directory -> do
        let draft = serviceRolePlanDraft cliServiceResources
            registry = fixtureServiceRegistry (Just selected) handlers
            spec =
                finalized $
                    addServices registry $
                        addSteps sampleChain $
                            builderWith passingSuite (pure ()) []
            cfg = Fixture.defaultProjectConfig "cli-service-runtime" (T.pack directory) Context.ClusterService
        executable <- getExecutablePath
        binaryBytes <- ByteString.readFile executable
        let binaryDigest = T.pack (show (Hash.hash binaryBytes :: Hash.Digest Hash.SHA256))
        withProductionProjectCodec @Fixture.ProjectConfig @Fixture.FixtureProject $ \baseCodec ->
            withFinalizedServiceRegistry ProductionScope baseCodec registry $ \codec finalizedRegistry -> do
                let roleWire =
                        TextEncoding.encodeUtf8 $
                            either error id $
                                withSelectedServiceProgram
                                    "projection-only"
                                    (inspectLocalContext (Fixture.context cfg))
                                    cfg
                                    finalizedRegistry
                                    (\_ roleCodec selectedRequest _ _ _ _ -> renderValidatedServiceRequest roleCodec selectedRequest)
                manifest <-
                    expectRight $
                        activationManifest
                            ( ActivationManifestInput
                                { manifestInputScope = "Production"
                                , manifestInputPlanDigest = "cli-service-plan"
                                , manifestInputSpecDigest = projectCodecSpecDigest codec
                                , manifestInputBinaryDigest = binaryDigest
                                , manifestInputFrame = localCurrentFrame (inspectLocalContext (Fixture.context cfg))
                                , manifestInputRevision = "cli-service-revision"
                                , manifestInputConfigDigest = digestBytes roleWire
                                , manifestInputSecretDigest = activationSecretDigestFromBytes ByteString.empty
                                , manifestInputService = T.pack selected
                                , manifestInputRolePlanDigest = rolePlanDraftDigest draft
                                , manifestInputPermittedEffects = ["network-listen"]
                                , manifestInputSecretChannel = "/run/hostbootstrap/empty"
                                }
                            )
                withBrokerFor [manifest] $ \broker store key -> do
                    revision <-
                        expectRight
                            =<< installServiceActivationRevision
                                broker
                                key
                                (directory </> "revisions")
                                manifest
                                roleWire
                                ByteString.empty
                    let keyPath = directory </> "activation.pub"
                    ByteString.writeFile keyPath (activationVerificationKeyBytes key)
                    withEnvironmentBindings
                        [ ("HOSTBOOTSTRAP_SERVICE_ACTIVATION", serviceActivationRevisionPath revision)
                        , ("HOSTBOOTSTRAP_ACTIVATION_KEY", keyPath)
                        , ("HOSTBOOTSTRAP_AUTHORITY_STORE", protectedStoreRoot store)
                        , ("HOSTBOOTSTRAP_SERVICE_INVOCATION_NONCE", "cli-service-instance")
                        ]
                        (use spec)

cliServiceResources :: ServiceResourceBackend
cliServiceResources =
    ServiceResourceBackend
        { serviceRolePlanDraft = either (error . show) id $ do
            request <- mkRoleResourceRequest "listener" False
            rolePlanDraft [request]
        , servicePrerequisite = pure PrereqSatisfied
        , serviceAcquireResource = \_ -> pure Acquired
        , serviceProbeResource = \_ -> pure ProbeReadyNow
        , serviceReleaseResource = \_ -> pure Released
        }

cliServiceBackend :: ServiceBackend CliServicePayloads
cliServiceBackend =
    ServiceBackend
        { backendServe = \pairs -> mapM_ snd pairs >> pure (Right ())
        , backendCall = \_ _ -> pure (Right ())
        , backendWork = \_ _ -> pure (Right ())
        }

assertMeasuredServiceInstanceRefused :: [(String, Maybe String)] -> T.Text -> IO ()
assertMeasuredServiceInstanceRefused instanceBindings expectedDiagnostic = do
    callbackRuns <- newIORef (0 :: Int)
    withVerifiedServiceRuntime "accelerator" [("accelerator", modifyIORef' callbackRuns (+ 1))] $ \spec -> do
        selectedRevision <- lookupEnv "HOSTBOOTSTRAP_SERVICE_ACTIVATION" >>= maybe (assertFailure "the genuine activation revision is absent") pure
        let missingRevision = selectedRevision </> replicate 64 '0'
        doesPathExist missingRevision >>= (@?= False)
        withEnvironmentBindings [("HOSTBOOTSTRAP_SERVICE_ACTIVATION", missingRevision)] $
            withMeasuredServiceInstanceEnvironment instanceBindings $ do
                (result, diagnostic) <- captureCLIExitStderr (withArgs ["service", "run"] (runHostBootstrapCLI spec))
                result @?= Left (ExitFailure 1)
                let observedDiagnostic =
                        if os == "mingw32"
                            then "service run: supply exactly Kubernetes pod UID plus restart count, or one host-service invocation nonce\n"
                            else expectedDiagnostic
                diagnostic @?= observedDiagnostic
    readIORef callbackRuns >>= (@?= 0)

withMeasuredServiceInstanceEnvironment :: [(String, Maybe String)] -> IO result -> IO result
withMeasuredServiceInstanceEnvironment bindings action =
    bracket
        (traverse (\(name, _) -> do old <- BlankEnvironment.getEnv name; pure (name, old)) bindings)
        (mapM_ restore)
        (\_ -> do
            mapM_ restore bindings
            rawValues <- traverse (\(name, _) -> do value <- BlankEnvironment.getEnv name; pure (name, value)) bindings
            rawValues @?= bindings
            ordinaryValues <- traverse (\(name, _) -> do value <- lookupEnv name; pure (name, value)) bindings
            let expectedOrdinaryValues =
                    [(name, if os == "mingw32" && value == Just "" then Nothing else value) | (name, value) <- bindings]
            ordinaryValues @?= expectedOrdinaryValues
            action
        )
  where
    restore (name, Just value) = BlankEnvironment.setEnv name value True
    restore (name, Nothing) = unsetEnv name

withEnvironmentBindings :: [(String, String)] -> IO result -> IO result
withEnvironmentBindings bindings action = do
    previous <- traverse (\(name, _) -> do old <- lookupEnv name; pure (name, old)) bindings
    mapM_ (uncurry setEnv) bindings
    action `finally` mapM_ restore previous
  where
    restore (name, Just old) = setEnv name old
    restore (name, Nothing) = unsetEnv name

digestBytes :: ByteString.ByteString -> T.Text
digestBytes bytes = T.pack (show (Hash.hash bytes :: Hash.Digest Hash.SHA256))

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

-- Harness derives its authority store from the working directory. A runtime
-- case therefore owns a fresh working directory, and leaves any operator store
-- under the suite's original directory untouched.
withIsolatedHarnessState :: IO result -> IO result
withIsolatedHarnessState action =
    withSystemTempDirectory "hostbootstrap-cli-harness" $ \stateRoot ->
        withCurrentDirectory stateRoot action

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

-- Probe the same temporary filesystem used by the cases, including effective
-- principal and ACL behavior; a permissions bit alone is not sufficient.
{-# NOINLINE readOnlyRecordsSupported #-}
readOnlyRecordsSupported :: Bool
readOnlyRecordsSupported = unsafePerformIO probeReadOnlyRecords

probeReadOnlyRecords :: IO Bool
probeReadOnlyRecords =
    withSystemTempDirectory "hostbootstrap-readonly-capability" $ \directory -> do
        permissions <- getPermissions directory
        changed <- try @IOException (setPermissions directory permissions{writable = False})
        case changed of
            Left failure
                | isPermissionError failure -> pure False
                | otherwise -> ioError failure
            Right () ->
                ( do
                    probe <- try @IOException $ bracket
                        (openBinaryTempFile directory ".write-probe")
                        (\(path, handle) -> hClose handle `finally` removeFile path)
                        (const (pure ()))
                    case probe of
                        Left failure
                            | isPermissionError failure -> pure True
                            | otherwise -> ioError failure
                        Right () -> pure False
                ) `finally` setPermissions directory permissions

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
            cleanup = removeIfPresent configPath
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
  where
    removeIfPresent path = do
        present <- doesFileExist path
        if present then removeFile path else pure ()

type ProtectedRecordImage = (T.Text, Word64, ByteString.ByteString)

-- Materialize the exact new Pending boundary in an isolated fixture, as if
-- the process died after its CAS but before allocating the Destroy epoch.
pendingDestroyAfterDown :: ByteString.ByteString -> IO ByteString.ByteString
pendingDestroyAfterDown bytes = do
    let magic = "HOSTBOOTSTRAP-REVERSE-ROOT"
        header =
            LazyByteString.toStrict . Builder.toLazyByteString $
                Builder.byteString magic <> Builder.word64BE 1 <> Builder.word64BE 28
        readFields :: Int -> ByteString.ByteString -> Either String [ByteString.ByteString]
        readFields 0 rest
            | ByteString.null rest = Right []
        readFields count rest
            | count > 0
            , ByteString.length rest >= 8 =
                let (encodedSize, payload) = ByteString.splitAt 8 rest
                    size = ByteString.foldl' (\value byte -> value * 256 + fromIntegral byte) (0 :: Word64) encodedSize
                 in if size <= fromIntegral (ByteString.length payload)
                        then
                            let (field, remaining) = ByteString.splitAt (fromIntegral size) payload
                             in (field :) <$> readFields (count - 1) remaining
                        else Left "truncated reverse-root fixture field"
        readFields _ _ = Left "invalid reverse-root fixture framing"
    ByteString.take (ByteString.length header) bytes @?= header
    fields <- either assertFailure pure (readFields 28 (ByteString.drop (ByteString.length header) bytes))
    length fields @?= 28
    take 2 fields @?= ["terminal", "down"]
    let pending = ["pending", "destroy"] ++ take 17 (drop 2 fields) ++ drop 24 fields
        frame field = Builder.word64BE (fromIntegral (ByteString.length field)) <> Builder.byteString field
    pure . LazyByteString.toStrict . Builder.toLazyByteString $
        Builder.byteString magic <> Builder.word64BE 1 <> Builder.word64BE 23 <> foldMap frame pending

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

fixtureRecordName :: T.Text -> T.Text
fixtureRecordName = either (error . show) id . mkRecordName

writeExactStableSnapshot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    ProjectPlan scope specDigest planId configId cfg ->
    IO ProtectedRecordImage
writeExactStableSnapshot store project plan = do
    let stable = renderSnapshot plan
        keyText = "snapshot." <> fixtureRecordName (installedProjectName project) <> recordTupleSeparator <> "production"
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
                let leasePrefix = "lease." <> fixtureRecordName projectName <> recordTupleSeparator
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
                            ( recordNameIdentity (T.drop (T.length leasePrefix) (recordKeyText key))
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
        (\_ _ -> pure ())
        [Case (fixtureCaseId "ok") AssertOnce]
        (\_ _ -> pure Pass)
        (pure ())

-- | A suite with no cases (rejected by the project-spec validator).
emptySuiteFixture :: TestSuite
emptySuiteFixture =
    TestSuite (pure (Right ())) (\_ _ -> pure ()) [] (\_ _ -> pure Pass) (pure ())

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

-- Preserve the real executable siblings even if a failing test unexpectedly
-- reaches publication or identity provisioning. Unchanged files are not rewritten.
withPreservedInitSiblings :: (T.Text -> [(FilePath, Maybe ByteString.ByteString)] -> IO result) -> IO result
withPreservedInitSiblings use = do
    projectName <- executableProjectName
    sibling <- Schema.siblingProjectConfigPath projectName
    executable <- getExecutablePath
    let paths =
            sibling
                : map (executable <>) [".handoff.key", ".handoff.pub", ".build.key", ".activation.key", ".activation.pub"]
        restoreFile original@(path, contents) = do
            current <- snapshotInitFile path
            if current == original
                then pure ()
                else case contents of
                    Just bytes -> ByteString.writeFile path bytes
                    Nothing -> do
                        present <- doesFileExist path
                        if present then removeFile path else pure ()
    bracket (traverse snapshotInitFile paths) (mapM_ restoreFile) (use projectName)

snapshotInitFile :: FilePath -> IO (FilePath, Maybe ByteString.ByteString)
snapshotInitFile path = do
    present <- doesFileExist path
    contents <- if present then Just <$> ByteString.readFile path else pure Nothing
    pure (path, contents)

-- | Run a command with stdout and stderr both captured, for refusals the report card prints
-- on one stream and a parser prints on the other.
captureCLIExitOutput :: IO () -> IO (Either ExitCode (), T.Text)
captureCLIExitOutput action =
    withSystemTempFile "hostbootstrap-cli-output" $ \_ captured -> do
        hFlush stdout
        hFlush stderr
        result <-
            bracket
                ((,) <$> hDuplicate stdout <*> hDuplicate stderr)
                ( \(savedOut, savedErr) -> do
                    hFlush stdout
                    hFlush stderr
                    hDuplicateTo savedOut stdout
                    hDuplicateTo savedErr stderr
                    hClose savedOut
                    hClose savedErr
                )
                (\_ -> hDuplicateTo captured stdout >> hDuplicateTo captured stderr >> try action)
        hSeek captured AbsoluteSeek 0
        output <- TIO.hGetContents captured
        pure (result, output)

-- | Run a command with only stdout captured, for output compared exactly.
captureCLIExitStdout :: IO () -> IO (Either ExitCode (), T.Text)
captureCLIExitStdout action =
    withSystemTempFile "hostbootstrap-cli-stdout" $ \_ captured -> do
        hFlush stdout
        result <-
            bracket
                (hDuplicate stdout)
                (\saved -> hFlush stdout `finally` (hDuplicateTo saved stdout `finally` hClose saved))
                (\_ -> hDuplicateTo captured stdout >> try action)
        hSeek captured AbsoluteSeek 0
        output <- TIO.hGetContents captured
        pure (result, output)

-- | A directory's regular files as sorted (relative path, bytes), recursively; absent is empty.
snapshotTree :: FilePath -> IO [(FilePath, ByteString.ByteString)]
snapshotTree root = do
    present <- doesDirectoryExist root
    if present then walk "" else pure []
  where
    walk relative = do
        entries <- sort <$> listDirectory (root </> relative)
        concat
            <$> traverse
                ( \entry -> do
                    let path = relative </> entry
                    isDirectory <- doesDirectoryExist (root </> path)
                    if isDirectory
                        then walk path
                        else (\bytes -> [(path, bytes)]) <$> ByteString.readFile (root </> path)
                )
                entries

-- | A project config whose current frame is a VM orchestrator under the host root, so it is off-root.
offRootProjectConfig :: T.Text -> Fixture.ProjectConfig scope
offRootProjectConfig projectName =
    base{Fixture.context = Context.deriveVMContext (Fixture.context base) "."}
  where
    base = Fixture.defaultProjectConfig projectName "." HostOrchestrator

-- | A service role wire's framework envelope, enough for the first-stage wire-kind check.
serviceRoleWireFixture :: T.Text
serviceRoleWireFixture =
    T.unlines
        [ "{ roleFrameworkValidation ="
        , "    { frameworkWireKind = < FullProjectWire | ServiceRoleWire >.ServiceRoleWire"
        , "    , frameworkScopeKind = < ProductionScope | HarnessScope >.ProductionScope"
        , "    , frameworkSpecDigest = \"digest\""
        , "    , frameworkLocalContext ="
        , "        { localProject = \"demo\""
        , "        , localBinary = \"demo\""
        , "        , localSourceRoot = \".\""
        , "        , localContextKind = < HostOrchestrator | VMOrchestrator | VMProjectContainer | ImageBuildContainer | ClusterService | Daemon | OneShotJob | TestHarness >.ClusterService"
        , "        , localRoleName = \"web\""
        , "        , localCurrentFrame = \"cluster-service-0\""
        , "        }"
        , "    }"
        , ", roleServiceFields = {=}"
        , "}"
        ]

captureCLIExitStderr :: IO () -> IO (Either ExitCode (), T.Text)
captureCLIExitStderr action =
    withSystemTempFile "hostbootstrap-cli-stderr" $ \_ captured -> do
        hFlush stderr
        result <-
            bracket
                (hDuplicate stderr)
                (\saved -> hFlush stderr `finally` (hDuplicateTo saved stderr `finally` hClose saved))
                (\_ -> hDuplicateTo captured stderr >> try action)
        hSeek captured AbsoluteSeek 0
        diagnostic <- TIO.hGetContents captured
        pure (result, diagnostic)

schemaFixtureOutput :: String -> IO T.Text
schemaFixtureOutput fixture = do
    executable <- getExecutablePath
    (exitCode, output, err) <-
        readProcessWithExitCode executable ["--hostbootstrap-schema-fixture", fixture] ""
    case exitCode of
        ExitSuccess -> pure (T.pack output)
        _ -> assertFailure ("schema fixture " ++ fixture ++ " failed: " ++ err)

-- | Run valid parser arguments under a deliberately different declared identity.
runIdentityMismatchProbe :: IO ()
runIdentityMismatchProbe = do
    actualProject <- executableProjectName
    withArgs ["context", "path"] $
        CLI.runHostBootstrapCLI
            (T.unpack (actualProject <> "-declared-mismatch"))
            (specWith passingSuite (pure ()) [])

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


bareBudgetRefusal :: [String] -> IO ()
bareBudgetRefusal arguments =
    withSystemTempDirectory "hostbootstrap-bare-budget-refusal" $ \directory ->
        withCurrentDirectory directory $
            withPreservedInitSiblings $ \projectName _ -> do
                let output = directory </> "bare.dhall"
                (result, _) <- captureCLIExitStderr $ withArgs (["project", "init", "--output", output] <> arguments) $ CLI.runBareHostBootstrapCLI (T.unpack projectName)
                result @?= Left (ExitFailure 1)
                listDirectory directory >>= (@?= [])
