{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module CLISpec (tests) where

import Control.Exception (finally, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import qualified Fixture
import HostBootstrap.CLI (
    ProjectSpec,
    projectSpec,
    runHostBootstrapCLI,
    withChain,
    withServices,
 )
import HostBootstrap.Command (coreCommandNames)
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Context (ContextKind (HostOrchestrator))
import HostBootstrap.Dhall.Gen (ConfigArtifact, artifactOf)
import HostBootstrap.Harness (
    Case (Case),
    CaseResult (Fail, Pass),
    TestSuite (TestSuite),
 )
import HostBootstrap.Service (ServiceHandler (ServiceHandler))
import HostBootstrap.Step (Step, StepFrame (..), deployVMStep)
import System.Directory (removeFile)
import System.Environment (withArgs)
import System.Exit (ExitCode (ExitFailure), die)
import System.FilePath (takeDirectory, (</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- | The fixture-backed project spec the CLI tests drive (generic over the
-- core-internal 'Fixture.ProjectConfig' + 'Fixture.TestConfig'). The init builders
-- are the fixture's, so @project init@ / @test init@ / @test run@ exercise the
-- real generic command machinery against a concrete config.
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
                let spec = withServices [ServiceHandler "web" (pure ())] (specWith passingSuite (pure ()) [])
                result <-
                    try (withArgs ["service", "run", "web"] (runHostBootstrapCLI "cli-svc-role" spec)) ::
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
        , testCase "project up fails fast without a sibling context" $ do
            result <-
                try (withArgs ["project", "up", "--dry-run"] (runHostBootstrapCLI "cli-project-nocfg" (withChain sampleChain (specWith passingSuite (pure ()) [])))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        ]

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
        (\_ -> pure ())

-- | A stack-driven suite whose single case asserts a failure.
failingSuite :: TestSuite
failingSuite =
    TestSuite
        (pure (Right ()))
        (\_ -> pure ())
        [Case "fails" 1 False]
        (\_ _ -> pure (Fail "seeded case failure"))
        (\_ -> pure ())

-- | A suite with no cases (rejected by the project-spec validator).
emptySuiteFixture :: TestSuite
emptySuiteFixture =
    TestSuite (pure (Right ())) (\_ -> pure ()) [] (\_ _ -> pure Pass) (\_ -> pure ())

-- | Write a fixture project config at the executable sibling path for a
-- gate-needing command, then remove it.
withProjectConfig :: String -> IO () -> IO ()
withProjectConfig rawProjectName action = do
    let projectName = T.pack rawProjectName
    path <- Schema.siblingProjectConfigPath projectName
    let cfg = Fixture.defaultProjectConfig projectName "/workspace/demo" HostOrchestrator
    (Schema.writeProjectConfigFile path cfg >> action) `finally` removeFile path
