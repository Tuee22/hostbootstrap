{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module CLISpec (tests) where

import Control.Exception (finally, throwIO, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import qualified Fixture
import HostBootstrap.CLI (
    ProjectSpec (psServices),
    projectSpec,
    runHostBootstrapCLI,
    withChain,
    withServiceConfig,
    withServices,
    withTeardown,
 )
import HostBootstrap.Command (coreCommandNames)
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Context (ContextKind (ClusterService, HostOrchestrator))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (ConfigArtifact, artifactOf)
import HostBootstrap.Harness (
    Case (Case),
    CaseResult (Fail, Pass),
    SafetyRefusal (SafetyRefusal),
    TestSuite (TestSuite),
 )
import HostBootstrap.Service (ServiceHandler (ServiceHandler), serviceVariantNames)
import HostBootstrap.Step (Step, StepFrame (..), deployVMStep, projectStep)
import System.Directory (doesDirectoryExist, doesFileExist, removeFile)
import System.Environment (lookupEnv, setEnv, unsetEnv, withArgs)
import System.Exit (ExitCode (ExitFailure), die)
import System.FilePath (takeDirectory, (</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

{- | The fixture-backed project spec the CLI tests drive (generic over the
core-internal 'Fixture.ProjectConfig' + 'Fixture.TestConfig'). The init builders
are the fixture's, so @project init@ / @test init@ / @test run@ exercise the
real generic command machinery against a concrete config.
-}
specWith ::
    TestSuite ->
    IO () ->
    [ConfigArtifact] ->
    ProjectSpec Fixture.ProjectConfig Fixture.TestConfig
specWith suite check arts =
    projectSpec suite check arts (Fixture.projectInit "cli") fixtureTestInit fixtureTestConfig

fixtureTestInit :: a -> Fixture.TestConfig
fixtureTestInit _ = Fixture.defaultTestConfig ["ok", "all"] (Fixture.Resources 4 "8GiB" "20GiB")

fixtureTestConfig :: Fixture.TestConfig -> IO [(T.Text, Fixture.ProjectConfig)]
fixtureTestConfig _ = pure [(T.pack "default", Fixture.defaultProjectConfig "cli" "/workspace/demo" HostOrchestrator)]

tests :: TestTree
tests =
    testGroup
        "CLISpec"
        [ testCase "project specs reject an empty test suite" $ do
            result <-
                try (withArgs ["--help"] (runHostBootstrapCLI "empty-suite" (specWith emptySuiteFixture (pure ()) []))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "core command surface has five user-facing verbs and no ensure command" $
            coreCommandNames @?= ["context", "project", "test", "service", "check-code"]
        , testCase "project specs reject duplicate service variants" $ do
            let dup =
                    withServices
                        [ServiceHandler "web" (pure ()), ServiceHandler "web" (pure ())]
                        (specWith passingSuite (pure ()) [])
            result <-
                try (withArgs ["--help"] (runHostBootstrapCLI "dup-svc" dup)) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "service registries compose additively across layers" $ do
            let layered =
                    withServices
                        [ServiceHandler "accelerator" (pure ())]
                        (withServices [ServiceHandler "web" (pure ())] (specWith passingSuite (pure ()) []))
            serviceVariantNames (psServices layered) @?= ["web", "accelerator"]
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
                        cfgPath
                        (Fixture.defaultProjectConfig "cli-test-existing" "/workspace/demo" HostOrchestrator)
                    result <-
                        try (withArgs ["test", "run", "all"] (runHostBootstrapCLI "cli-test-existing" spec)) ::
                            IO (Either ExitCode ())
                    result @?= Left (ExitFailure 1)
                )
                `finally` (removeFile testPath >> removeFile cfgPath)
        , testCase "service schema lists variants without a config" $ do
            let spec = withServices [ServiceHandler "web" (pure ())] (specWith passingSuite (pure ()) [])
            result <-
                try (withArgs ["service", "schema"] (runHostBootstrapCLI "cli-svc-schema" spec)) ::
                    IO (Either ExitCode ())
            result @?= Right ()
        , testCase "service run fails fast on a non-service-role config" $
            withProjectConfig "cli-svc-role" $ do
                let spec = configuredService "web" (withServices [ServiceHandler "web" (pure ())] (specWith passingSuite (pure ()) []))
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI "cli-svc-role" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "service run rejects a multi-role orchestrator even when ServiceCommand is granted" $
            withMultiRoleHostServiceConfig "cli-svc-multirole" $ do
                handlerRan <- newIORef False
                let spec = configuredService "web" (withServices [ServiceHandler "web" (writeIORef handlerRan True)] (specWith passingSuite (pure ()) []))
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
                        configuredService "accelerator" $
                            withServices
                                [ ServiceHandler "web" (writeIORef webRan True)
                                , ServiceHandler "accelerator" (writeIORef acceleratorRan True)
                                ]
                                (specWith passingSuite (pure ()) [])
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI "cli-svc-dispatch" spec)) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef webRan >>= (@?= False)
                readIORef acceleratorRan >>= (@?= True)
        , testCase "service run rejects a legacy positional variant" $
            withServiceProjectConfig "cli-svc-positional" $ do
                let spec = configuredService "web" (withServices [ServiceHandler "web" (pure ())] (specWith passingSuite (pure ()) []))
                result <-
                    try (withArgs ["service", "run", "web"] (runHostBootstrapCLI "cli-svc-positional" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "service run fails fast for an empty registry" $
            withServiceProjectConfig "cli-svc-empty" $ do
                let spec = configuredService "accelerator" (specWith passingSuite (pure ()) [])
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI "cli-svc-empty" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "service run fails fast for an unknown variant" $
            withServiceProjectConfig "cli-svc-unknown" $ do
                let spec = configuredService "accelerator" (withServices [ServiceHandler "web" (pure ())] (specWith passingSuite (pure ()) []))
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI "cli-svc-unknown" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "service run refuses a service-role config with no configured variant" $
            withServiceProjectConfig "cli-svc-unconfigured" $ do
                let spec = withServices [ServiceHandler "web" (pure ())] (specWith passingSuite (pure ()) [])
                result <-
                    try (withArgs ["service", "run"] (runHostBootstrapCLI "cli-svc-unconfigured" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "the fixed service surface has no down command" $
            withServiceProjectConfig "cli-svc-no-down" $ do
                let spec = withServices [ServiceHandler "web" (pure ())] (specWith passingSuite (pure ()) [])
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
            let arts = [artifactOf @V.Budget "localBudget" (V.Budget 1 2 3)]
            result <-
                try (withArgs ["context", "render", "--artifact", "localBudget"] (runHostBootstrapCLI "cli-render-local" (specWith passingSuite (pure ()) arts))) ::
                    IO (Either ExitCode ())
            result @?= Right ()
        , testCase "project up --dry-run renders the chain through the context gate" $
            withProjectConfig "cli-project-dryrun" $ do
                result <-
                    try (withArgs ["project", "up", "--dry-run"] (runHostBootstrapCLI "cli-project-dryrun" (withChain sampleChain (specWith passingSuite (pure ()) [])))) ::
                        IO (Either ExitCode ())
                result @?= Right ()
        , testCase "project up safety refusal skips automatic project teardown" $
            withProjectConfig "cli-project-safety" $ do
                teardownCalls <- newIORef (0 :: Int)
                let frame = StepFrame "host-orchestrator-0" "metal"
                    refusingChain _ = [projectStep "safety-refusal" "probe ownership" frame (\_ -> throwIO (SafetyRefusal "pre-existing state"))]
                    spec =
                        withTeardown
                            (\_ _ -> writeIORef teardownCalls 1)
                            (withChain refusingChain (specWith passingSuite (pure ()) []))
                result <-
                    try (withArgs ["project", "up"] (runHostBootstrapCLI "cli-project-safety" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
                readIORef teardownCalls >>= (@?= 0)
        , testCase "project up fails fast without a sibling context" $ do
            result <-
                try (withArgs ["project", "up", "--dry-run"] (runHostBootstrapCLI "cli-project-nocfg" (withChain sampleChain (specWith passingSuite (pure ()) [])))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        ]

configuredService :: String -> ProjectSpec Fixture.ProjectConfig Fixture.TestConfig -> ProjectSpec Fixture.ProjectConfig Fixture.TestConfig
configuredService variant = withServiceConfig (const (Right variant))

-- A one-step demo-shaped chain used to prove `project up --dry-run` renders.
sampleChain :: Fixture.ProjectConfig -> [Step]
sampleChain _ =
    [deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (const (pure ()))]

-- | A stack-driven suite with a trivial bring-up and a single passing assertion.
passingSuite :: TestSuite
passingSuite =
    TestSuite
        (pure (Right ()))
        (\_ -> pure ())
        [Case "ok" 1 False]
        (\_ _ -> pure Pass)
        (pure ())

-- | A stack-driven suite whose single case asserts a failure.
failingSuite :: TestSuite
failingSuite =
    TestSuite
        (pure (Right ()))
        (\_ -> pure ())
        [Case "fails" 1 False]
        (\_ _ -> pure (Fail "seeded case failure"))
        (pure ())

-- | A suite with no cases (rejected by the project-spec validator).
emptySuiteFixture :: TestSuite
emptySuiteFixture =
    TestSuite (pure (Right ())) (\_ -> pure ()) [] (\_ _ -> pure Pass) (pure ())

{- | Write a fixture project config at the executable sibling path for a
gate-needing command, then remove it.
-}
withProjectConfig :: String -> IO () -> IO ()
withProjectConfig rawProjectName action = do
    let projectName = T.pack rawProjectName
    path <- Schema.siblingProjectConfigPath projectName
    let cfg = Fixture.defaultProjectConfig projectName "/workspace/demo" HostOrchestrator
    (Schema.writeProjectConfigFile path cfg >> action) `finally` removeFile path

withMultiRoleHostServiceConfig :: String -> IO () -> IO ()
withMultiRoleHostServiceConfig rawProjectName action = do
    let projectName = T.pack rawProjectName
        baseCfg = Fixture.defaultProjectConfig projectName "/workspace/demo" HostOrchestrator
        cfg = baseCfg{Fixture.context = Context.addRole ClusterService (Fixture.context baseCfg)}
    path <- Schema.siblingProjectConfigPath projectName
    (Schema.writeProjectConfigFile path cfg >> action) `finally` removeFile path

withServiceProjectConfig :: String -> IO () -> IO ()
withServiceProjectConfig rawProjectName action = do
    let projectName = T.pack rawProjectName
        witnessName = "HOSTBOOTSTRAP_CURRENT_FRAME"
        parentCfg = Fixture.defaultProjectConfig projectName "/workspace/demo" HostOrchestrator
        cfg = parentCfg{Fixture.context = Context.deriveHostDaemonContext (Fixture.context parentCfg) "/workspace/demo"}
        frame = T.unpack (Context.currentFrame (Fixture.context cfg))
    path <- Schema.siblingProjectConfigPath projectName
    previous <- lookupEnv witnessName
    let restore = do
            removeFile path
            maybe (unsetEnv witnessName) (setEnv witnessName) previous
    (Schema.writeProjectConfigFile path cfg >> setEnv witnessName frame >> action) `finally` restore
