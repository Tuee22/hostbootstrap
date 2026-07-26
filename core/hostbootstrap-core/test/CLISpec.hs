{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module CLISpec (runSchemaFixture, tests) where

import Control.Exception (finally, throwIO, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Fixture
import HostBootstrap.CLI (
    ProjectSpec,
    ProjectSpecBuilder,
    ProjectSpecError (..),
    addArtifacts,
    addAssemblyInputs,
    addServices,
    addSteps,
    finalizeProjectSpec,
    projectServiceVariantNames,
    projectArtifactNames,
    projectStepPlan,
    projectSpec,
    setFrameContext,
    setTeardown,
 )
import qualified HostBootstrap.CLI as CLI
import HostBootstrap.Command (coreCommandNames)
import HostBootstrap.Config.Class (AssemblyRequest (..), ConfigAssembly, ProjectCfg (withProductionProjectCodec), configInput, pureConfigAssembly)
import HostBootstrap.Config.Fields (ScopeKind (ProductionScope))
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Context (ContextKind (ClusterService, HostOrchestrator))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (ConfigArtifact, artifactOf, autoCodecWitness, requireCodecWitness)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Harness (
    Case (Case),
    CaseId,
    CaseResult (Fail, Pass),
    SafetyRefusal (SafetyRefusal),
    TestSuite (TestSuite),
    mkCaseId,
 )
import HostBootstrap.Lift (localContext)
import HostBootstrap.Service (
    ServiceRegistry,
    ServiceRegistryError (..),
    emptyServiceRegistry,
    serviceRoleSchemaFamilies,
    serviceDefinition,
    serviceId,
    serviceRegistry,
    withFinalizedServiceRegistry,
 )
import HostBootstrap.Step (ProjectStepId, ReversePolicy (ProjectManagedReverse), Step, StepFrame (..), StepPlanError (DuplicateStepIdentities), deployVMStep, projectStep, projectStepId, stepLabel, stepPlanSteps)
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory, removeFile)
import System.Environment (getExecutablePath, lookupEnv, setEnv, unsetEnv, withArgs, withProgName)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), die)
import System.FilePath (takeDirectory, (</>))
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
    ProjectSpecBuilder Fixture.FixtureProject Fixture.ProjectConfig Fixture.TestConfig
builderWith suite check arts =
    projectSpec suite check arts Fixture.testConfigCodec fixtureTestInit fixtureAssemble

specWith ::
    TestSuite ->
    IO () ->
    [ConfigArtifact] ->
    ProjectSpec Fixture.FixtureProject Fixture.ProjectConfig Fixture.TestConfig
specWith suite check arts =
    finalized
        ( addSteps
            sampleChain
            ( setFrameContext
                (\_ _ _ -> localContext)
                (setTeardown (\_ _ _ -> pure ()) (builderWith suite check arts))
            )
        )

finalized ::
    ProjectSpecBuilder Fixture.FixtureProject Fixture.ProjectConfig Fixture.TestConfig ->
    ProjectSpec Fixture.FixtureProject Fixture.ProjectConfig Fixture.TestConfig
finalized = either (error . show) id . finalizeProjectSpec

fixtureTestInit :: a -> Fixture.TestConfig
fixtureTestInit _ = Fixture.defaultTestConfig (Fixture.Resources 4 "8GiB" "20GiB")

fixtureAssemble ::
    forall scope.
    AssemblyRequest Fixture.FixtureProject Fixture.TestConfig T.Text scope ->
    ConfigAssembly scope (Fixture.ProjectConfig scope)
fixtureAssemble request =
    case request of
        ProductionAssembly args ->
            pureConfigAssembly (Fixture.projectInit "cli" args)
        HarnessAssembly _ _ _ ->
            pureConfigAssembly (Fixture.defaultProjectConfig "cli" "/workspace/demo" HostOrchestrator)

runHostBootstrapCLI ::
    String ->
    ProjectSpec Fixture.FixtureProject Fixture.ProjectConfig Fixture.TestConfig ->
    IO ()
runHostBootstrapCLI name spec =
    withProgName name (CLI.runHostBootstrapCLI name spec)

tests :: TestTree
tests =
    testGroup
        "CLISpec"
        [ testCase "project specs reject an empty test suite before dispatch" $
            case finalizeProjectSpec
                ( addSteps
                    sampleChain
                    ( setFrameContext
                        (\_ _ _ -> localContext)
                        (setTeardown (\_ _ _ -> pure ()) (builderWith emptySuiteFixture (pure ()) []))
                    )
                ) of
                Left EmptyProjectTestSuite -> pure ()
                other -> assertFailure ("expected EmptyProjectTestSuite, got " ++ either show (const "Right ProjectSpec") other)
        , testCase "runtime executable identity must match the declared project" $ do
            result <-
                try
                    ( withProgName "actual-project" $
                        CLI.runHostBootstrapCLI
                            "declared-project"
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
                                setFrameContext (\_ _ _ -> localContext) $
                                    setTeardown (\_ _ _ -> pure ()) $
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
                                    setFrameContext (\_ _ _ -> localContext) $
                                        setTeardown (\_ _ _ -> pure ()) $
                                            builderWith passingSuite (pure ()) []
                                )
                            )
            projectServiceVariantNames layered @?= ["web", "accelerator"]
        , testCase "an empty registry has structured Production and Harness schema families" $ do
            let schemas =
                    withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \baseCodec ->
                        withFinalizedServiceRegistry
                            ProductionScope
                            baseCodec
                            emptyServiceRegistry
                            (\_ registry -> serviceRoleSchemaFamilies registry)
            assertBool "Production empty family is explicit" ("service schema family Production:\n  services = []\n  schemas = []" `T.isInfixOf` schemas)
            assertBool "Harness empty family is explicit" ("service schema family Harness:\n  services = []\n  schemas = []" `T.isInfixOf` schemas)
        , testCase "single-assignment projections reject missing and duplicate values" $ do
            case finalizeProjectSpec (addSteps sampleChain (builderWith passingSuite (pure ()) [])) of
                Left MissingFrameContext -> pure ()
                other -> assertFailure ("expected MissingFrameContext, got " ++ either show (const "Right ProjectSpec") other)
            let duplicated =
                    setFrameContext (\_ _ _ -> localContext) $
                        setFrameContext (\_ _ _ -> localContext) $
                            setTeardown (\_ _ _ -> pure ()) $
                                addSteps sampleChain (builderWith passingSuite (pure ()) [])
            case finalizeProjectSpec duplicated of
                Left (DuplicateFrameContextAssignments 2) -> pure ()
                other -> assertFailure ("expected duplicate frame-context rejection, got " ++ either show (const "Right ProjectSpec") other)
        , testCase "independent step fragments append in exact declaration order" $ do
            let first _ =
                    [projectStep (fixtureProjectStepId "first-fragment") ProjectManagedReverse "first" (StepFrame "host-orchestrator-0" "host") (const (pure ()))]
                second _ =
                    [projectStep (fixtureProjectStepId "second-fragment") ProjectManagedReverse "second" (StepFrame "host-orchestrator-0" "host") (const (pure ()))]
                spec =
                    finalized $
                        addSteps second $
                            addSteps first $
                                setFrameContext (\_ _ _ -> localContext) $
                                    setTeardown (\_ _ _ -> pure ()) $
                                        builderWith passingSuite (pure ()) []
                cfg = Fixture.defaultProjectConfig "cli-fragments" "." HostOrchestrator
            plan <- either (assertFailure . show) pure (projectStepPlan spec cfg)
            map stepLabel (stepPlanSteps plan) @?= ["first", "second"]
        , testCase "artifact fragments compose associatively without erasure" $ do
            let budgetCodec = requireCodecWitness "CLISpec.Budget" (autoCodecWitness @V.Budget)
                firstArtifact = artifactOf "fragmentA" budgetCodec (V.Budget 1 2 3)
                secondArtifact = artifactOf "fragmentB" budgetCodec (V.Budget 2 3 4)
                finish builder =
                    finalized $
                        addSteps sampleChain $
                            setFrameContext (\_ _ _ -> localContext) $
                                setTeardown (\_ _ _ -> pure ()) builder
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
                                setFrameContext (\_ _ _ -> localContext) $
                                    setTeardown (\_ _ _ -> pure ()) $
                                        builderWith passingSuite (pure ()) []
            case finalizeProjectSpec builder of
                Left (DuplicateAssemblyInputs ["settings.dhall"]) -> pure ()
                other -> assertFailure ("expected duplicate assembly-input rejection, got " ++ either show (const "validated") other)
        , testCase "duplicate identities across additive fragments fail before interpretation" $ do
            let duplicate _ =
                    [projectStep (fixtureProjectStepId "shared") ProjectManagedReverse "duplicate" (StepFrame "host-orchestrator-0" "host") (const (pure ()))]
                spec =
                    finalized $
                        addSteps duplicate $
                            addSteps duplicate $
                                setFrameContext (\_ _ _ -> localContext) $
                                    setTeardown (\_ _ _ -> pure ()) $
                                        addArtifacts [] (builderWith passingSuite (pure ()) [])
                cfg = Fixture.defaultProjectConfig "cli-duplicates" "." HostOrchestrator
            case projectStepPlan spec cfg of
                Left (DuplicateStepIdentities _) -> pure ()
                other -> assertFailure ("expected duplicate step rejection, got " ++ either show (const "validated") other)
        , testCase "check-code runs the project-supplied hook" $ do
            ran <- newIORef False
            withProjectConfig "cli-check-hook" $ do
                result <-
                    try (withArgs ["check-code"] (runHostBootstrapCLI "cli-check-hook" (specWith passingSuite (writeIORef ran True) []))) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef ran >>= (@?= True)
        , testCase "check-code exits non-zero when the hook fails" $
            withProjectConfig "cli-check-fail" $ do
                result <-
                    try (withArgs ["check-code"] (runHostBootstrapCLI "cli-check-fail" (specWith passingSuite (die "seeded check failure") []))) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "test run fails fast without a test.dhall" $
            withProjectConfig "cli-test-notdhall" $ do
                result <-
                    try (withArgs ["test", "run", "all"] (runHostBootstrapCLI "cli-test-notdhall" (specWith passingSuite (pure ()) []))) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "test init writes a test config without a pre-existing project config" $ do
            cfgPath <- Schema.siblingProjectConfigPath "cli-test-init"
            let testPath = takeDirectory cfgPath </> "cli-test-init.test.dhall"
            ( do
                    result <-
                        try (withArgs ["test", "init"] (runHostBootstrapCLI "cli-test-init" (specWith passingSuite (pure ()) []))) ::
                            IO (Either ExitCode ())
                    result @?= Right ()
                )
                `finally` removeFile testPath
        , testCase "test init then test run exits non-zero when a case fails (config is generated then removed)" $ do
            cfgPath <- Schema.siblingProjectConfigPath "cli-test-fail"
            let testPath = takeDirectory cfgPath </> "cli-test-fail.test.dhall"
            ( do
                    _ <-
                        try (withArgs ["test", "init"] (runHostBootstrapCLI "cli-test-fail" (specWith failingSuite (pure ()) []))) ::
                            IO (Either ExitCode ())
                    result <-
                        try (withArgs ["test", "run", "all"] (runHostBootstrapCLI "cli-test-fail" (specWith failingSuite (pure ()) []))) ::
                            IO (Either ExitCode ())
                    result @?= Left (ExitFailure 1)
                    doesFileExist cfgPath >>= (@?= False)
                    doesDirectoryExist (cfgPath ++ ".hostbootstrap-test-owner") >>= (@?= False)
                )
                `finally` removeFile testPath
        , testCase "test run refuses to overwrite an existing sibling project config" $ do
            cfgPath <- Schema.siblingProjectConfigPath "cli-test-existing"
            let testPath = takeDirectory cfgPath </> "cli-test-existing.test.dhall"
                spec = specWith passingSuite (pure ()) []
            ( do
                    _ <-
                        try (withArgs ["test", "init"] (runHostBootstrapCLI "cli-test-existing" spec)) ::
                            IO (Either ExitCode ())
                    Schema.writeProjectConfigFile
                        Fixture.projectConfigCodec
                        cfgPath
                        (Fixture.defaultProjectConfig "cli-test-existing" "/workspace/demo" HostOrchestrator)
                    result <-
                        try (withArgs ["test", "run", "all"] (runHostBootstrapCLI "cli-test-existing" spec)) ::
                            IO (Either ExitCode ())
                    result @?= Left (ExitFailure 1)
                )
                `finally` (removeFile testPath >> removeFile cfgPath)
        , testCase "service schema lists variants without a config" $ do
            let spec = specWithServices Nothing [("web", pure ())]
            result <-
                try (withArgs ["service", "schema"] (runHostBootstrapCLI "cli-svc-schema" spec)) ::
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
        , testCase "service run fails fast on a non-service-role config" $
            withProjectConfig "cli-svc-role" $ do
                let spec = specWithServices (Just "web") [("web", pure ())]
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI "cli-svc-role" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "service run rejects a multi-role orchestrator even when ServiceCommand is granted" $
            withMultiRoleHostServiceConfig "cli-svc-multirole" $ do
                handlerRan <- newIORef False
                let spec = specWithServices (Just "web") [("web", writeIORef handlerRan True)]
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI "cli-svc-multirole" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
                readIORef handlerRan >>= (@?= False)
        , testCase "service run dispatches exactly the selected variant from a multi-handler registry" $
            withServiceProjectConfig "cli-svc-dispatch" $ do
                webRan <- newIORef False
                acceleratorRan <- newIORef False
                let spec =
                        specWithServices
                            (Just "accelerator")
                            [ ("web", writeIORef webRan True)
                            , ("accelerator", writeIORef acceleratorRan True)
                            ]
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI "cli-svc-dispatch" spec)) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef webRan >>= (@?= False)
                readIORef acceleratorRan >>= (@?= True)
        , testCase "service run rejects a legacy positional variant" $
            withServiceProjectConfig "cli-svc-positional" $ do
                let spec = specWithServices (Just "web") [("web", pure ())]
                result <-
                    try (withArgs ["service", "run", "web"] (runHostBootstrapCLI "cli-svc-positional" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "service run fails fast for an empty registry" $
            withServiceProjectConfig "cli-svc-empty" $ do
                let spec = specWithServices (Just "accelerator") []
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI "cli-svc-empty" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "service run fails fast for an unknown variant" $
            withServiceProjectConfig "cli-svc-unknown" $ do
                let spec = specWithServices (Just "accelerator") [("web", pure ())]
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI "cli-svc-unknown" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "service run refuses a service-role config with no configured variant" $
            withServiceProjectConfig "cli-svc-unconfigured" $ do
                let spec = specWithServices Nothing [("web", pure ())]
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI "cli-svc-unconfigured" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "the fixed service surface has no down command" $
            withServiceProjectConfig "cli-svc-no-down" $ do
                let spec = specWithServices Nothing [("web", pure ())]
                result <-
                    try (withArgs ["service", "down"] (runHostBootstrapCLI "cli-svc-no-down" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "context render fails fast on an unknown artifact" $ do
            result <-
                try (withArgs ["context", "render", "--artifact", "missing"] (runHostBootstrapCLI "cli-render-missing" (specWith passingSuite (pure ()) []))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "context render sees project artifacts from the spec" $ do
            let budgetCodec = requireCodecWitness "CLISpec.Budget" (autoCodecWitness @V.Budget)
                arts = [artifactOf "localBudget" budgetCodec (V.Budget 1 2 3)]
            result <-
                try (withArgs ["context", "render", "--artifact", "localBudget"] (runHostBootstrapCLI "cli-render-local" (specWith passingSuite (pure ()) arts))) ::
                    IO (Either ExitCode ())
            result @?= Right ()
        , testCase "project up --dry-run renders the chain through the context gate" $
            withProjectConfig "cli-project-dryrun" $ do
                result <-
                    try (withArgs ["project", "up", "--dry-run"] (runHostBootstrapCLI "cli-project-dryrun" (specWith passingSuite (pure ()) []))) ::
                        IO (Either ExitCode ())
                result @?= Right ()
        , testCase "project up safety refusal skips automatic project teardown" $
            withProjectConfig "cli-project-safety" $ do
                teardownCalls <- newIORef (0 :: Int)
                let frame = StepFrame "host-orchestrator-0" "metal"
                    refusingChain _ =
                        [ projectStep
                            (fixtureProjectStepId "safety-refusal")
                            ProjectManagedReverse
                            "probe ownership"
                            frame
                            (\_ -> throwIO (SafetyRefusal "pre-existing state"))
                        ]
                    spec =
                        finalized $
                            addSteps refusingChain $
                                setFrameContext (\_ _ _ -> localContext) $
                                    setTeardown
                                        (\_ _ _ -> writeIORef teardownCalls 1)
                                        (builderWith passingSuite (pure ()) [])
                result <-
                    try (withArgs ["project", "up"] (runHostBootstrapCLI "cli-project-safety" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
                readIORef teardownCalls >>= (@?= 0)
        , testCase "project down skips host kind cleanup when deploy-kind belongs to no current-frame step" $
            withProjectConfig "cli-project-down-nested" $ do
                teardownCalls <- newIORef (0 :: Int)
                let spec =
                        finalized $
                            addSteps sampleChain $
                                setFrameContext (\_ _ _ -> localContext) $
                                    setTeardown
                                        (\_ _ _ -> writeIORef teardownCalls 1)
                                        (builderWith passingSuite (pure ()) [])
                result <-
                    try (withArgs ["project", "down"] (runHostBootstrapCLI "cli-project-down-nested" spec)) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef teardownCalls >>= (@?= 1)
        , testCase "project up fails fast without a sibling context" $ do
            result <-
                try (withArgs ["project", "up", "--dry-run"] (runHostBootstrapCLI "cli-project-nocfg" (specWith passingSuite (pure ()) []))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        ]

specWithServices ::
    Maybe String ->
    [(String, IO ())] ->
    ProjectSpec Fixture.FixtureProject Fixture.ProjectConfig Fixture.TestConfig
specWithServices selected handlers =
    finalized $
        addServices
            (fixtureServiceRegistry selected handlers)
            ( addSteps sampleChain $
                setFrameContext (\_ _ _ -> localContext) $
                    setTeardown (\_ _ _ -> pure ()) $
                        builderWith passingSuite (pure ()) []
            )

fixtureServiceRegistry ::
    Maybe String ->
    [(String, IO ())] ->
    ServiceRegistry (Fixture.ProjectConfig (V.Production Fixture.FixtureProject))
fixtureServiceRegistry selected handlers =
    either (error . show) id $
        serviceRegistry
            [ serviceDefinition
                (either error id (serviceId name))
                (\_ -> Right (if selected == Just name then Just () else Nothing))
                (\_ _ -> handler)
            | (name, handler) <- handlers
            ]

-- A one-step demo-shaped chain used to prove `project up --dry-run` renders.
sampleChain :: Fixture.ProjectConfig scope -> [Step]
sampleChain _ =
    [deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (const (pure ()))]

fixtureProjectStepId :: String -> ProjectStepId
fixtureProjectStepId = either error id . projectStepId

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
withProjectConfig :: String -> IO () -> IO ()
withProjectConfig rawProjectName action = do
    let projectName = T.pack rawProjectName
    path <- Schema.siblingProjectConfigPath projectName
    let cfg = Fixture.defaultProjectConfig projectName "." HostOrchestrator
    (Schema.writeProjectConfigFile Fixture.projectConfigCodec path cfg >> action) `finally` removeFile path

withMultiRoleHostServiceConfig :: String -> IO () -> IO ()
withMultiRoleHostServiceConfig rawProjectName action = do
    let projectName = T.pack rawProjectName
        baseCfg = Fixture.defaultProjectConfig projectName "." HostOrchestrator
        cfg = baseCfg{Fixture.context = Context.addRole ClusterService (Fixture.context baseCfg)}
    path <- Schema.siblingProjectConfigPath projectName
    (Schema.writeProjectConfigFile Fixture.projectConfigCodec path cfg >> action) `finally` removeFile path

withServiceProjectConfig :: String -> IO () -> IO ()
withServiceProjectConfig rawProjectName action = do
    let projectName = T.pack rawProjectName
        witnessName = "HOSTBOOTSTRAP_CURRENT_FRAME"
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
runSchemaFixture fixture =
    case fixture of
        "bare" ->
            withArgs ["context", "schema"] $
                withProgName "hostbootstrap" (CLI.runBareHostBootstrapCLI "hostbootstrap")
        "consumer" -> do
            let budgetCodec = requireCodecWitness "CLISpec.Budget" (autoCodecWitness @V.Budget)
                arts = [artifactOf "localBudget" budgetCodec (V.Budget 1 2 3)]
            withArgs ["context", "schema"] $
                runHostBootstrapCLI "cli-schema-consumer" (specWith passingSuite (pure ()) arts)
        "service" -> do
            let spec = specWithServices Nothing [("web", pure ())]
            withArgs ["service", "schema"] $
                runHostBootstrapCLI "cli-schema-service" spec
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
