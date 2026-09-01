module RecoveryInterruptionSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import qualified RecursiveLifecycleSpec
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Info (os)
import System.Process (spawnProcess, terminateProcess, waitForProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "recovery-interruption"
        [ boundaryCase "owned-resource-settled" (Just ["host"])
        , boundaryCase "migration-frozen" Nothing
        , boundaryCase "migration-committed" Nothing
        , boundaryCase "closing-persisted" Nothing
        , destroySettlementCase
        ]

destroySettlementCase :: TestTree
destroySettlementCase =
    testCase "destroy-settled survives a real process death with terminal lease and mode" $
        unless (os == "mingw32") $ RecursiveLifecycleSpec.withFixtureEnvironment False $ \root _ -> do
            RecursiveLifecycleSpec.runPublicProcess root False "up" >>= (@?= ExitSuccess)
            let readyPath = root </> "destroy-ready"
            producer <- RecursiveLifecycleSpec.spawnDestroyInterruptionProbe root readyPath
            awaitFile readyPath
            readFile readyPath >>= (@?= "destroy-settled")
            terminateProcess producer
            _ <- waitForProcess producer
            RecursiveLifecycleSpec.runPublicProcess root False "up" >>= (@?= ExitSuccess)
            RecursiveLifecycleSpec.runPublicProcess root False "destroy" >>= (@?= ExitSuccess)

boundaryCase :: String -> Maybe [String] -> TestTree
boundaryCase boundary expectedEvents =
    testCase (boundary ++ " survives a real process death and converges") $
        withSystemTempDirectory ("hostbootstrap-recovery-interruption-" ++ boundary) $ \root -> do
            self <- getExecutablePath
            let readyPath = root </> "ready"
                resultPath = root </> "result"
                eventsPath = root </> "recovery.events"
            producer <-
                spawnProcess
                    self
                    ["--hostbootstrap-recovery-interruption-probe", root, readyPath, boundary]
            awaitFile readyPath
            readFile readyPath >>= (@?= boundary)
            terminateProcess producer
            _ <- waitForProcess producer
            successor <-
                spawnProcess
                    self
                    ["--hostbootstrap-recovery-interruption-successor", root, resultPath, boundary]
            waitForProcess successor >>= (@?= ExitSuccess)
            doesFileExist resultPath >>= (@?= True)
            result <- readFile resultPath
            unless (result == "converged\n" || result == "refused-exactly\n") $
                assertFailure ("unexpected successor result: " ++ show result)
            case expectedEvents of
                Nothing -> pure ()
                Just expected -> do
                    doesFileExist eventsPath >>= (@?= True)
                    lines <$> readFile eventsPath >>= (@?= expected)

awaitFile :: FilePath -> IO ()
awaitFile path = go (200 :: Int)
  where
    go 0 = assertFailure ("timed out waiting for subprocess sentinel " ++ path)
    go remaining = do
        exists <- doesFileExist path
        if exists
            then pure ()
            else threadDelay 25000 >> go (remaining - 1)
