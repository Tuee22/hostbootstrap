{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module CLISpec (tests) where

import Control.Exception (finally, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import HostBootstrap.CLI (
    projectCommand,
    projectSpec,
    runHostBootstrapCLI,
 )
import qualified HostBootstrap.Config.Schema as Schema
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Context (ContextKind (HostOrchestrator))
import HostBootstrap.Dhall.Gen (artifactOf)
import HostBootstrap.Harness (
    Case (Case),
    CaseResult (Fail, Pass),
    Seams (..),
    TestSuite (TestSuite),
    emptySuite,
 )
import Options.Applicative (info, progDesc)
import System.Directory (removeFile)
import System.Environment (withArgs)
import System.Exit (ExitCode (ExitFailure), die)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "CLISpec"
        [ testCase "project specs reject an empty test suite" $ do
            result <-
                try (withArgs ["--help"] (runHostBootstrapCLI "empty-suite" (projectSpec [] emptySuite (pure ()) []))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "project specs reject commands that shadow core commands" $ do
            let shadow = projectCommand "test" (info (pure (pure ())) (progDesc "shadow test"))
            result <-
                try (withArgs ["--help"] (runHostBootstrapCLI "shadow-cli" (projectSpec [shadow] passingSuite (pure ()) []))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "check-code runs the project-supplied hook" $ do
            ran <- newIORef False
            withProjectConfig "cli-check-hook" $ do
                result <-
                    try (withArgs ["check-code"] (runHostBootstrapCLI "cli-check-hook" (projectSpec [] passingSuite (writeIORef ran True) []))) ::
                        IO (Either ExitCode ())
                result @?= Right ()
                readIORef ran >>= (@?= True)
        , testCase "check-code exits non-zero when the hook fails" $
            withProjectConfig "cli-check-fail" $ do
                result <-
                    try (withArgs ["check-code"] (runHostBootstrapCLI "cli-check-fail" (projectSpec [] passingSuite (die "seeded check failure") []))) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "test exits non-zero when any case fails" $
            withProjectConfig "cli-test-fail" $ do
                result <-
                    try (withArgs ["test", "all"] (runHostBootstrapCLI "cli-test-fail" (projectSpec [] failingSuite (pure ()) []))) ::
                        IO (Either ExitCode ())
                result @?= Left (ExitFailure 1)
        , testCase "config render fails fast on an unknown artifact" $ do
            result <-
                try (withArgs ["config", "render", "--artifact", "missing"] (runHostBootstrapCLI "cli-render-missing" (projectSpec [] passingSuite (pure ()) []))) ::
                    IO (Either ExitCode ())
            result @?= Left (ExitFailure 1)
        , testCase "config render sees project artifacts from the spec" $ do
            let arts = [artifactOf @V.Budget "localBudget" (V.Budget 1 2 3)]
            result <-
                try (withArgs ["config", "render", "--artifact", "localBudget"] (runHostBootstrapCLI "cli-render-local" (projectSpec [] passingSuite (pure ()) arts))) ::
                    IO (Either ExitCode ())
            result @?= Right ()
        ]

passingSuite :: TestSuite
passingSuite =
    TestSuite
        Seams
            { seamSetup = \_ -> pure ()
            , seamRun = \_ _ -> pure Pass
            , seamTeardown = \_ _ -> pure ()
            }
        [Case "ok" 1 False]

failingSuite :: TestSuite
failingSuite =
    TestSuite
        Seams
            { seamSetup = \_ -> pure ()
            , seamRun = \_ _ -> pure (Fail "seeded case failure")
            , seamTeardown = \_ _ -> pure ()
            }
        [Case "fails" 1 False]

withProjectConfig :: String -> IO () -> IO ()
withProjectConfig rawProjectName action = do
    let projectName = T.pack rawProjectName
    path <- Schema.siblingProjectConfigPath projectName
    let cfg = Schema.defaultProjectConfig projectName "/workspace/demo" HostOrchestrator
    (Schema.writeProjectConfigFile path cfg >> action) `finally` removeFile path
