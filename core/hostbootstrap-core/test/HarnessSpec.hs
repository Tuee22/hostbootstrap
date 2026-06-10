{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module HarnessSpec (tests) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (find, isInfixOf)
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Cluster.Lifecycle (ClusterProfile (TestCase))
import HostBootstrap.Harness
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "HarnessSpec"
    [ testGroup "per-case isolation + teardown" matrixCases,
      testGroup "test-suite selection" suiteCases,
      testGroup "guardTestDelete" guardCases,
      testGroup "budget-slicing" sliceCases,
      testGroup "run-model selection" runModelCases,
      testGroup "OneShot run argv" oneShotCases
    ]

oneShotCases :: [TestTree]
oneShotCases =
  [ testCase "docker run --rm is budget-capped, mount-bound, and command-tailed" $
      oneShotRunArgs
        OneShotSpec
          { oneShotImage = "demo:linux-cpu-amd64",
            oneShotCommand = ["test", "web-build"],
            oneShotCpus = 6,
            oneShotMemoryBytes = 10 * 1024 * 1024 * 1024,
            oneShotMounts = [V.Mount {V.source = "./.test_data", V.target = "/data", V.readOnly = False}],
            oneShotInteractive = False
          }
        @?= [ "run",
              "--rm",
              "--cpus",
              "6",
              "--memory",
              show (10 * 1024 * 1024 * 1024 :: Integer),
              "-v",
              "./.test_data:/data",
              "demo:linux-cpu-amd64",
              "test",
              "web-build"
            ],
    testCase "interactive adds -it and a read-only mount gets :ro" $
      oneShotRunArgs
        OneShotSpec
          { oneShotImage = "img",
            oneShotCommand = [],
            oneShotCpus = 1,
            oneShotMemoryBytes = 1024,
            oneShotMounts = [V.Mount {V.source = "/host", V.target = "/in", V.readOnly = True}],
            oneShotInteractive = True
          }
        @?= ["run", "--rm", "-it", "--cpus", "1", "--memory", "1024", "-v", "/host:/in:ro", "img"]
  ]

matrixCases :: [TestTree]
matrixCases =
  [ testCase "testCaseProfile isolates each case" $
      testCaseProfile (Case "case1" 1 False) @?= TestCase "case1",
    testCase "teardown runs for every case, even when the body fails" $ do
      tornDown <- newIORef []
      let seams =
            Seams
              { seamSetup = \c -> pure (caseId c),
                seamRun = \_ c ->
                  if caseId c == "boom" then ioError (userError "kaboom") else pure Pass,
                seamTeardown = \env _ -> modifyIORef' tornDown (env :)
              }
      report <- runMatrix seams [Case "ok" 1 False, Case "boom" 1 False]
      td <- readIORef tornDown
      assertBool "both cases torn down" ("ok" `elem` td && "boom" `elem` td)
      lookup "ok" (reportResults report) @?= Just Pass
      case lookup "boom" (reportResults report) of
        Just (Fail msg) -> assertBool ("failure mentions the cause: " ++ msg) ("kaboom" `isInfixOf` msg)
        other -> assertFailure ("expected boom to Fail, got " ++ show other)
      allPassed report @?= False
  ]

suiteCases :: [TestTree]
suiteCases =
  [ testCase "emptySuite `all` renders 0/0 passed" $ do
      outcome <- runSuiteSelection emptySuite allCasesSelector
      case outcome of
        Right report -> assertBool "report card shows 0/0" ("0/0 passed" `isInfixOf` reportCard report)
        Left err -> assertFailure ("expected Right, got Left " ++ err),
    testCase "`all` runs the whole matrix" $ do
      outcome <- runSuiteSelection twoCaseSuite allCasesSelector
      case outcome of
        Right (Report rs) -> map fst rs @?= ["a", "b"]
        Left err -> assertFailure ("expected Right, got Left " ++ err),
    testCase "a named case runs only that case" $ do
      outcome <- runSuiteSelection twoCaseSuite "b"
      case outcome of
        Right (Report rs) -> map fst rs @?= ["b"]
        Left err -> assertFailure ("expected Right, got Left " ++ err),
    testCase "an unknown case fails fast, listing the valid ids and `all`" $ do
      outcome <- runSuiteSelection twoCaseSuite "nope"
      case outcome of
        Left err ->
          assertBool
            ("names the valid ids + all: " ++ err)
            ("a" `isInfixOf` err && "b" `isInfixOf` err && "all" `isInfixOf` err)
        Right _ -> assertFailure "expected Left for an unknown case"
  ]
  where
    twoCaseSuite = TestSuite passSeams [Case "a" 1 False, Case "b" 1 False]
    passSeams =
      Seams
        { seamSetup = \_ -> pure (),
          seamRun = \_ _ -> pure Pass,
          seamTeardown = \_ _ -> pure ()
        }

guardCases :: [TestTree]
guardCases =
  [ testCase "a prefixed test cluster name is allowed" $
      guardTestDelete "demo-test-" "demo-test-case1" @?= Right "demo-test-case1",
    testCase "a non-prefixed (production) name is refused" $
      guardTestDelete "demo-test-" "demo"
        @?= Left (NotPrefixed "demo-test-" "demo")
  ]

sliceCases :: [TestTree]
sliceCases =
  [ testCase "divisible cases split by weight; indivisible get the full budget" $ do
      let budget = V.Budget 10 20 40
          cases = [Case "a" 1 False, Case "b" 1 False, Case "gpu" 1 True]
          sliced = sliceBudget budget cases
      sliceFor "a" sliced @?= Just (V.Budget 5 10 20)
      sliceFor "b" sliced @?= Just (V.Budget 5 10 20)
      sliceFor "gpu" sliced @?= Just (V.Budget 10 20 40),
    testCase "concurrent divisible slices sum within budget (floor never overcommits)" $ do
      let budget = V.Budget 7 7 7
          cases = [Case "a" 1 False, Case "b" 2 False]
          divisible = [s | (c, s) <- sliceBudget budget cases, not (caseIndivisible c)]
          totalCpu = sum [b.cpu | b <- divisible]
      assertBool "cpu slices sum within budget" (totalCpu <= 7),
    testCase "splitByWeight floors proportionally" $
      splitByWeight (V.Budget 10 20 40) [1, 1] @?= [V.Budget 5 10 20, V.Budget 5 10 20]
  ]
  where
    sliceFor cid sliced = snd <$> find ((== cid) . caseId . fst) sliced

runModelCases :: [TestTree]
runModelCases =
  [ testCase "cluster topology selects Cluster" $
      selectRunModel (RunModelKey ClusterTopology False) @?= Cluster,
    testCase "daemon topology selects HostDaemon" $
      selectRunModel (RunModelKey DaemonTopology False) @?= HostDaemon,
    testCase "container-only with a host-native build selects HostNative" $
      selectRunModel (RunModelKey ContainerOnly True) @?= HostNative,
    testCase "container-only without host-native selects OneShot" $
      selectRunModel (RunModelKey ContainerOnly False) @?= OneShot
  ]
