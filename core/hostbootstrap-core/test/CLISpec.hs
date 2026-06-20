{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module CLISpec (tests) where

import Control.Exception (finally, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import HostBootstrap.CLI (
    projectSpec,
    runHostBootstrapCLI,
    withChain,
    withServices,
 )
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Context (ContextKind (HostOrchestrator))
import HostBootstrap.Dhall.Gen (artifactOf)
import HostBootstrap.Harness (
    Case (Case),
    CaseResult (Fail, Pass),
    TestSuite (TestSuite),
 )
import HostBootstrap.Service (ServiceHandler (ServiceHandler))
import HostBootstrap.Step (Step, StepFrame (..), deployVMStep)
import System.Directory (removeFile)
import System.Environment (withArgs)
import System.FilePath (takeDirectory, (</>))
import System.Exit (ExitCode (ExitFailure), die)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "CLISpec"
        [ testCase "project specs reject an empty test suite" $ do
            result <-
                try (withArgs ["--help"] (runHostBootstrapCLI "empty-suite" (projectSpec emptySuiteFixture (pure ()) []))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "project specs reject duplicate service variants" $ do
            let dup =
                    withServices
                        [ServiceHandler "web" (pure ()), ServiceHandler "web" (pure ())]
                        (projectSpec passingSuite (pure ()) [])
            result <-
                try (withArgs ["--help"] (runHostBootstrapCLI "dup-svc" dup)) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "check-code runs the project-supplied hook" $ do
            ran <- newIORef False
            withProjectConfig "cli-check-hook" $ do
                result <-
                    try (withArgs ["check-code"] (runHostBootstrapCLI "cli-check-hook" (projectSpec passingSuite (writeIORef ran True) []))) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef ran >>= (@?= True)
        , testCase "check-code exits non-zero when the hook fails" $
            withProjectConfig "cli-check-fail" $ do
                result <-
                    try (withArgs ["check-code"] (runHostBootstrapCLI "cli-check-fail" (projectSpec passingSuite (die "seeded check failure") []))) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "test run fails fast without a test.dhall" $
            withProjectConfig "cli-test-notdhall" $ do
                result <-
                    try (withArgs ["test", "run", "all"] (runHostBootstrapCLI "cli-test-notdhall" (projectSpec passingSuite (pure ()) []))) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "test init then test run exits non-zero when a case fails" $
            withProjectConfig "cli-test-fail" $ do
                cfgPath <- Schema.siblingProjectConfigPath "cli-test-fail"
                let testPath = takeDirectory cfgPath </> "cli-test-fail.test.dhall"
                ( do
                    _ <-
                        try (withArgs ["test", "init"] (runHostBootstrapCLI "cli-test-fail" (projectSpec failingSuite (pure ()) []))) ::
                            IO (Either ExitCode ())
                    result <-
                        try (withArgs ["test", "run", "all"] (runHostBootstrapCLI "cli-test-fail" (projectSpec failingSuite (pure ()) []))) ::
                            IO (Either ExitCode ())
                    result @?= Left (ExitFailure 1)
                    )
                    `finally` removeFile testPath
        , testCase "service schema lists variants without a config" $ do
            let spec = withServices [ServiceHandler "web" (pure ())] (projectSpec passingSuite (pure ()) [])
            result <-
                try (withArgs ["service", "schema"] (runHostBootstrapCLI "cli-svc-schema" spec)) ::
                    IO (Either ExitCode ())
            result @?= Right ()
        , testCase "service run fails fast on a non-service-role config" $
            withProjectConfig "cli-svc-role" $ do
                let spec = withServices [ServiceHandler "web" (pure ())] (projectSpec passingSuite (pure ()) [])
                result <-
                    try (withArgs ["service", "run", "web"] (runHostBootstrapCLI "cli-svc-role" spec)) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "context render fails fast on an unknown artifact" $ do
            result <-
                try (withArgs ["context", "render", "--artifact", "missing"] (runHostBootstrapCLI "cli-render-missing" (projectSpec passingSuite (pure ()) []))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "context render sees project artifacts from the spec" $ do
            let arts = [artifactOf @V.Budget "localBudget" (V.Budget 1 2 3)]
            result <-
                try (withArgs ["context", "render", "--artifact", "localBudget"] (runHostBootstrapCLI "cli-render-local" (projectSpec passingSuite (pure ()) arts))) ::
                    IO (Either ExitCode ())
            result @?= Right ()
        , testCase "project up --dry-run renders the chain through the context gate" $
            withProjectConfig "cli-project-dryrun" $ do
                result <-
                    try (withArgs ["project", "up", "--dry-run"] (runHostBootstrapCLI "cli-project-dryrun" (withChain sampleChain (projectSpec passingSuite (pure ()) [])))) ::
                        IO (Either ExitCode ())
                result @?= Right ()
        , testCase "project up fails fast without a sibling context" $ do
            result <-
                try (withArgs ["project", "up", "--dry-run"] (runHostBootstrapCLI "cli-project-nocfg" (withChain sampleChain (projectSpec passingSuite (pure ()) [])))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        ]

-- A one-step demo-shaped chain used to prove `project up --dry-run` renders.
sampleChain :: Schema.ProjectConfig -> [Step]
sampleChain _ =
    [deployVMStep "launch the VM" (StepFrame "host-orchestrator-0" "metal") (const (pure ()))]

-- | A stack-driven suite with a trivial bring-up and a single passing assertion.
passingSuite :: TestSuite
passingSuite =
    TestSuite
        (pure (Right ()))
        (pure ())
        [Case "ok" 1 False]
        (\_ _ -> pure Pass)
        (\_ -> pure ())

-- | A stack-driven suite whose single case asserts a failure.
failingSuite :: TestSuite
failingSuite =
    TestSuite
        (pure (Right ()))
        (pure ())
        [Case "fails" 1 False]
        (\_ _ -> pure (Fail "seeded case failure"))
        (\_ -> pure ())

-- | A suite with no cases (rejected by the project-spec validator).
emptySuiteFixture :: TestSuite
emptySuiteFixture =
    TestSuite (pure (Right ())) (pure ()) [] (\_ _ -> pure Pass) (\_ -> pure ())

withProjectConfig :: String -> IO () -> IO ()
withProjectConfig rawProjectName action = do
    let projectName = T.pack rawProjectName
    path <- Schema.siblingProjectConfigPath projectName
    let cfg = Schema.defaultProjectConfig projectName "/workspace/demo" HostOrchestrator
    (Schema.writeProjectConfigFile path cfg >> action) `finally` removeFile path
