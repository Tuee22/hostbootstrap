{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module HarnessSpec (tests) where

import Control.Exception (SomeException, finally, throwIO, try)
import Control.Monad (when)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (find, isInfixOf)
import qualified Data.Text as T
import HostBootstrap.Cluster.Lifecycle (ClusterProfile (TestCase))
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Harness
import System.Directory (doesDirectoryExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "HarnessSpec"
        [ testGroup "per-case isolation + teardown" matrixCases
        , testGroup "test-suite selection" suiteCases
        , testGroup "guardTestDelete" guardCases
        , testGroup "budget-slicing" sliceCases
        , testGroup "run-model selection" runModelCases
        , testGroup "OneShot run argv" oneShotCases
        ]

oneShotCases :: [TestTree]
oneShotCases =
    [ testCase "docker run --rm is budget-capped, mount-bound, and command-tailed" $
        oneShotRunArgs
            OneShotSpec
                { oneShotImage = "demo:linux-cpu-amd64"
                , oneShotCommand = ["test", "web-build"]
                , oneShotCpus = 6
                , oneShotMemoryBytes = 10 * 1024 * 1024 * 1024
                , oneShotMounts = [V.Mount{V.source = "./.test_data", V.target = "/data", V.readOnly = False}]
                , oneShotInteractive = False
                }
            @?= [ "run"
                , "--rm"
                , "--cpus"
                , "6"
                , "--memory"
                , show (10 * 1024 * 1024 * 1024 :: Integer)
                , "-v"
                , "./.test_data:/data"
                , "demo:linux-cpu-amd64"
                , "test"
                , "web-build"
                ]
    , testCase "interactive adds -it and a read-only mount gets :ro" $
        oneShotRunArgs
            OneShotSpec
                { oneShotImage = "img"
                , oneShotCommand = []
                , oneShotCpus = 1
                , oneShotMemoryBytes = 1024
                , oneShotMounts = [V.Mount{V.source = "/host", V.target = "/in", V.readOnly = True}]
                , oneShotInteractive = True
                }
            @?= ["run", "--rm", "-it", "--cpus", "1", "--memory", "1024", "-v", "/host:/in:ro", "img"]
    ]

matrixCases :: [TestTree]
matrixCases =
    [ testCase "testCaseProfile isolates each case" $
        testCaseProfile (Case "case1" 1 False) @?= TestCase "case1"
    , testCase "teardown runs for every case, even when the body fails" $ do
        tornDown <- newIORef []
        let seams =
                Seams
                    { seamSetup = \c -> pure (caseId c)
                    , seamRun = \_ c ->
                        if caseId c == "boom" then ioError (userError "kaboom") else pure Pass
                    , seamTeardown = \env _ -> modifyIORef' tornDown (env :)
                    }
        report <- runMatrix seams [Case "ok" 1 False, Case "boom" 1 False]
        td <- readIORef tornDown
        assertBool "both cases torn down" ("ok" `elem` td && "boom" `elem` td)
        lookup "ok" (reportResults report) @?= Just Pass
        case lookup "boom" (reportResults report) of
            Just (Fail msg) -> assertBool ("failure mentions the cause: " ++ msg) ("kaboom" `isInfixOf` msg)
            other -> assertFailure ("expected boom to Fail, got " ++ show other)
        allPassed report @?= False
    , testCase "a throwing setup fails that case without crashing the matrix" $ do
        let seams =
                Seams
                    { seamSetup = \c ->
                        if caseId c == "boom" then ioError (userError "setup-kaboom") else pure (caseId c)
                    , seamRun = \_ _ -> pure Pass
                    , seamTeardown = \_ _ -> pure ()
                    }
        report <- runMatrix seams [Case "boom" 1 False, Case "ok" 1 False]
        case lookup "boom" (reportResults report) of
            Just (Fail msg) -> assertBool ("setup failure surfaced: " ++ msg) ("setup-kaboom" `isInfixOf` msg)
            other -> assertFailure ("expected boom to Fail, got " ++ show other)
        lookup "ok" (reportResults report) @?= Just Pass
    ]

suiteCases :: [TestTree]
suiteCases =
    [ testCase "emptySuite `all` renders 0/0 passed" $ do
        outcome <- runSuiteSelection emptySuite [oneVariant] allCasesSelector
        case outcome of
            Right report -> assertBool "report card shows 0/0" ("0/0 passed" `isInfixOf` reportCard report)
            Left err -> assertFailure ("expected Right, got Left " ++ err)
    , testCase "`all` runs the whole matrix (rows labeled by variant)" $ do
        outcome <- runSuiteSelection twoCaseSuite [oneVariant] allCasesSelector
        case outcome of
            Right (Report rs) -> map fst rs @?= ["[v0] a", "[v0] b"]
            Left err -> assertFailure ("expected Right, got Left " ++ err)
    , testCase "a named case runs only that case" $ do
        outcome <- runSuiteSelection twoCaseSuite [oneVariant] "b"
        case outcome of
            Right (Report rs) -> map fst rs @?= ["[v0] b"]
            Left err -> assertFailure ("expected Right, got Left " ++ err)
    , testCase "two variants loop with full teardown + spin-up, aggregating labeled rows" $ do
        events <- newIORef []
        let record e = modifyIORef' events (e :)
            suite =
                TestSuite
                    (pure (Right ()))
                    (\label -> record ("up:" ++ T.unpack label) >> pure label)
                    [Case "a" 1 False]
                    (\label _ -> record ("assert:" ++ T.unpack label) >> pure Pass)
                    (record "down")
        outcome <- runSuiteSelection suite [variant "v0", variant "v1"] allCasesSelector
        seen <- reverse <$> readIORef events
        case outcome of
            Right (Report rs) -> map fst rs @?= ["[v0] a", "[v1] a"]
            Left err -> assertFailure ("expected Right, got Left " ++ err)
        -- Each variant fully completes (up -> assert -> down) before the next starts.
        seen @?= ["up:v0", "assert:v0", "down", "up:v1", "assert:v1", "down"]
    , testCase "a failed bring-up still runs teardown and isolates the variant" $ do
        events <- newIORef []
        let record e = modifyIORef' events (e :)
            -- v0's bring-up throws; v1's succeeds. v0 must still tear down, fail its
            -- case, and NOT abort v1.
            suite =
                TestSuite
                    (pure (Right ()))
                    ( \label ->
                        if label == T.pack "v0"
                            then record "up:v0-boom" >> ioError (userError "project up kaboom")
                            else record ("up:" ++ T.unpack label) >> pure label
                    )
                    [Case "a" 1 False]
                    (\label _ -> record ("assert:" ++ T.unpack label) >> pure Pass)
                    (record "down")
        outcome <- runSuiteSelection suite [variant "v0", variant "v1"] allCasesSelector
        seen <- reverse <$> readIORef events
        case outcome of
            Right (Report rs) -> do
                -- v0's case Fails (bring-up), v1's case Passes — the loop was not aborted.
                lookup "[v0] a" rs @?= Just (Fail "bring-up failed: user error (project up kaboom)")
                lookup "[v1] a" rs @?= Just Pass
            Left err -> assertFailure ("expected Right, got Left " ++ err)
        -- v0 tore down despite its failed bring-up; v1 ran normally.
        seen @?= ["up:v0-boom", "down", "up:v1", "assert:v1", "down"]
    , testCase "a failed teardown fails that variant instead of hiding a leak" $ do
        downCount <- newIORef (0 :: Int)
        let tearDown = do
                modifyIORef' downCount (+ 1)
                count <- readIORef downCount
                when (count == 1) (ioError (userError "destroy left managed state"))
            suite =
                TestSuite
                    (pure (Right ()))
                    pure
                    [Case "a" 1 False]
                    (\_ _ -> pure Pass)
                    tearDown
        outcome <- runSuiteSelection suite [variant "v0", variant "v1"] allCasesSelector
        case outcome of
            Right (Report rs) -> do
                case lookup "[v0] a" rs of
                    Just (Fail msg) -> assertBool "teardown cause is reported" ("destroy left managed state" `isInfixOf` msg)
                    other -> assertFailure ("expected v0 teardown failure, got " ++ show other)
                lookup "[v1] a" rs @?= Just Pass
            Left err -> assertFailure ("expected Right, got Left " ++ err)
    , testCase "a safety refusal never tears down state the harness did not own" $ do
        teardownCalls <- newIORef (0 :: Int)
        configEntries <- newIORef (0 :: Int)
        configExits <- newIORef (0 :: Int)
        let suite =
                TestSuite
                    (pure (Right ()))
                    (\_ -> throwIO (SafetyRefusal "pre-existing managed VM"))
                    [Case "a" 1 False]
                    (\_ _ -> pure Pass)
                    (modifyIORef' teardownCalls (+ 1))
            withConfig body = do
                modifyIORef' configEntries (+ 1)
                body `finally` modifyIORef' configExits (+ 1)
        outcome <- runSuiteSelection suite [ConfigVariant "v0" withConfig] allCasesSelector
        case outcome of
            Right (Report rs) ->
                case lookup "[v0] a" rs of
                    Just (Fail msg) -> assertBool "refusal is visible" ("pre-existing managed VM" `isInfixOf` msg)
                    other -> assertFailure ("expected safety refusal failure, got " ++ show other)
            Left err -> assertFailure ("expected Right, got Left " ++ err)
        readIORef teardownCalls >>= (@?= 0)
        readIORef configEntries >>= (@?= 1)
        readIORef configExits >>= (@?= 1)
    , testCase "an unknown case fails fast, listing the valid ids and `all`" $ do
        outcome <- runSuiteSelection twoCaseSuite [oneVariant] "nope"
        case outcome of
            Left err ->
                assertBool
                    ("names the valid ids + all: " ++ err)
                    ("a" `isInfixOf` err && "b" `isInfixOf` err && "all" `isInfixOf` err)
            Right _ -> assertFailure "expected Left for an unknown case"
    ]
  where
    -- A stack-driven suite (label-aware bring-up, passing assertions) — exercises
    -- `runSuiteSelection`'s case selection over the new TestSuite shape.
    twoCaseSuite =
        TestSuite
            (pure (Right ()))
            pure
            [Case "a" 1 False, Case "b" 1 False]
            (\_ _ -> pure Pass)
            (pure ())
    variant label = ConfigVariant (T.pack label) id
    oneVariant = variant "v0"

guardCases :: [TestTree]
guardCases =
    [ testCase "a prefixed test cluster name is allowed" $
        guardTestDelete "demo-test-" "demo-test-case1" @?= Right "demo-test-case1"
    , testCase "a non-prefixed (production) name is refused" $
        guardTestDelete "demo-test-" "demo"
            @?= Left (NotPrefixed "demo-test-" "demo")
    , testCase "self-created .test_data is removed; a found one is preserved" $ do
        selfCreatedTestDataRemoval False testDataRoot @?= [testDataRoot]
        selfCreatedTestDataRemoval True testDataRoot @?= []
    , testCase "self-created test data and its ownership lock are removed after an exception" $
        withSystemTempDirectory "hostbootstrap-test-data" $ \root -> do
            let path = root </> ".test_data"
                lockPath = path ++ ".hostbootstrap-run-owner"
            outcome <- try (withSelfCreatedTestData path (throwIO (userError "seeded failure"))) :: IO (Either SomeException ())
            assertBool "body exception propagated" (either (const True) (const False) outcome)
            doesDirectoryExist path >>= (@?= False)
            doesDirectoryExist lockPath >>= (@?= False)
    ]

sliceCases :: [TestTree]
sliceCases =
    [ testCase "divisible cases split by weight; indivisible get the full budget" $ do
        let budget = V.Budget 10 20 40
            cases = [Case "a" 1 False, Case "b" 1 False, Case "gpu" 1 True]
            sliced = sliceBudget budget cases
        sliceFor "a" sliced @?= Just (V.Budget 5 10 20)
        sliceFor "b" sliced @?= Just (V.Budget 5 10 20)
        sliceFor "gpu" sliced @?= Just (V.Budget 10 20 40)
    , testCase "concurrent divisible slices sum within budget (floor never overcommits)" $ do
        let budget = V.Budget 7 7 7
            cases = [Case "a" 1 False, Case "b" 2 False]
            divisible = [s | (c, s) <- sliceBudget budget cases, not (caseIndivisible c)]
            totalCpu = sum [b.cpu | b <- divisible]
        assertBool "cpu slices sum within budget" (totalCpu <= 7)
    , testCase "splitByWeight floors proportionally" $
        splitByWeight (V.Budget 10 20 40) [1, 1] @?= [V.Budget 5 10 20, V.Budget 5 10 20]
    ]
  where
    sliceFor cid sliced = snd <$> find ((== cid) . caseId . fst) sliced

runModelCases :: [TestTree]
runModelCases =
    [ testCase "cluster topology selects Cluster" $
        selectRunModel (RunModelKey ClusterTopology False) @?= Cluster
    , testCase "daemon topology selects HostDaemon" $
        selectRunModel (RunModelKey DaemonTopology False) @?= HostDaemon
    , testCase "container-only with a host-native build selects HostNative" $
        selectRunModel (RunModelKey ContainerOnly True) @?= HostNative
    , testCase "container-only without host-native selects OneShot" $
        selectRunModel (RunModelKey ContainerOnly False) @?= OneShot
    ]
