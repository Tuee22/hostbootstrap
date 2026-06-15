{-# LANGUAGE OverloadedStrings #-}

module CordonSpec (tests) where

import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import HostBootstrap.Cluster.Cordon
import HostBootstrap.Config.Schema (Resources (..))
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Sysctl), mkAbsExe)
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import System.Directory (findExecutable)
import qualified System.Info as Info
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

gib :: Integer
gib = 1024 ^ (3 :: Integer)

mib :: Integer
mib = 1024 ^ (2 :: Integer)

demoResources :: Resources
demoResources = Resources {cpu = 4, memory = "8GiB", storage = "20GiB"}

tests :: TestTree
tests =
  testGroup
    "CordonSpec"
    [ testGroup "parseQuantity" quantityCases,
      testGroup "budget" budgetCases,
      testGroup "verifyBudget" verifyCases,
      testGroup "host capacity source" capacitySourceCases,
      testGroup "fitsBudget" fitsCases,
      testGroup "sizing + applied cordon" sizingCases
    ]

quantityCases :: [TestTree]
quantityCases =
  [ testCase "8Gi binary" (parseQuantity "8Gi" @?= Right (8 * gib)),
    testCase "8GiB binary (B suffix)" (parseQuantity "8GiB" @?= Right (8 * gib)),
    testCase "512Mi binary" (parseQuantity "512Mi" @?= Right (512 * mib)),
    testCase "1G decimal" (parseQuantity "1G" @?= Right 1000000000),
    testCase "bare number is bytes" (parseQuantity "1024" @?= Right 1024),
    testCase "whitespace tolerated" (parseQuantity "  4Gi " @?= Right (4 * gib)),
    testCase "unknown unit rejected" (isLeft (parseQuantity "8Qi") @?= True),
    testCase "empty rejected" (isLeft (parseQuantity "") @?= True)
  ]

budgetCases :: [TestTree]
budgetCases =
  [ testCase "resources -> canonical byte budget" $
      budgetFromResources demoResources
        @?= Right (ResourceBudget 4 (8 * gib) (20 * gib)),
    testCase "gibibytes rounds up" $
      map gibibytes [gib, gib + 1, 8 * gib] @?= [1, 2, 8]
  ]

verifyCases :: [TestTree]
verifyCases =
  [ testCase "within spare capacity passes" $
      verifyBudget budget (HostCapacity 8 (16 * gib) (100 * gib)) @?= Right (),
    testCase "cpu over capacity fails naming cpu" $
      leftHas "cpu" (verifyBudget budget (HostCapacity 2 (16 * gib) (100 * gib))),
    testCase "memory over capacity fails naming memory" $
      leftHas "memory" (verifyBudget budget (HostCapacity 8 (4 * gib) (100 * gib))),
    testCase "storage over capacity fails naming storage" $
      leftHas "storage" (verifyBudget budget (HostCapacity 8 (16 * gib) (10 * gib)))
  ]
  where
    budget = ResourceBudget 4 (8 * gib) (20 * gib)

capacitySourceCases :: [TestTree]
capacitySourceCases =
  [ testCase "apple-silicon reads CPU and memory from sysctl" $
      capacityReadPlan (Substrate AppleSilicon Arm64)
        @?= CapacityReadPlan (SysctlKey "hw.ncpu") (SysctlKey "hw.memsize"),
    testCase "linux-cpu reads CPU and memory from procfs" $
      capacityReadPlan (Substrate LinuxCpu Amd64)
        @?= CapacityReadPlan ProcCpuinfo ProcMemAvailable,
    testCase "linux-gpu reads CPU and memory from procfs" $
      capacityReadPlan (Substrate LinuxGpu Amd64)
        @?= CapacityReadPlan ProcCpuinfo ProcMemAvailable,
    testCase "apple sysctl core count can satisfy a matching N-core budget" $
      preflightBudget
        (Resources {cpu = 10, memory = "8GiB", storage = "20GiB"})
        (HostCapacity 10 (16 * gib) petabyte)
        @?= Right (),
    testCase "live apple-silicon sysctl read resolves positive capacity" $ do
      if Info.os == "darwin" && Info.arch `elem` ["aarch64", "arm64"]
        then do
          sysctl <- findExecutable "sysctl"
          case sysctl >>= either (const Nothing) Just . mkAbsExe of
            Nothing -> assertBool "expected sysctl to resolve to an absolute path" False
            Just exe -> do
              result <-
                resolveHostCapacity
                  HostConfig
                    { hcSubstrate = Substrate AppleSilicon Arm64,
                      hcToolPaths = Map.singleton Sysctl exe
                    }
              case result of
                Right capacity ->
                  assertBool "expected positive CPU and memory capacity" $
                    spareCpu capacity > 0 && spareMemoryBytes capacity > 0
                Left err -> assertBool ("expected sysctl capacity read to succeed, got: " ++ err) False
        else pure ()
  ]
  where
    petabyte = 1024 ^ (5 :: Integer)

fitsCases :: [TestTree]
fitsCases =
  [ testCase "a fitting pod set is accepted" $
      fitsBudget (V.Budget 4 8 20) [V.PodResources 2 1 1 1 2] @?= Right (),
    testCase "an over-cpu pod set is rejected naming cpu" $
      fitsBudget (V.Budget 2 8 20) [V.PodResources 3 1 2 1 1]
        @?= Left (Overflow "cpu" 6 2),
    testCase "an over-memory pod set is rejected naming memory" $
      fitsBudget (V.Budget 8 4 20) [V.PodResources 3 1 1 1 4]
        @?= Left (Overflow "memory" 12 4),
    testCase "preflightBudget passes within spare capacity" $
      preflightBudget demoResources (HostCapacity 8 (16 * gib) (100 * gib)) @?= Right (),
    testCase "preflightBudget fails fast when short" $
      leftHas "cpu" (preflightBudget demoResources (HostCapacity 2 (16 * gib) (100 * gib)))
  ]

sizingCases :: [TestTree]
sizingCases =
  [ testCase "colima sizing emits the full profiled argv" $
      colimaSizingArgs "demo" demoResources
        @?= Right ["start", "--profile", "demo", "--cpu", "4", "--memory", "8", "--disk", "20"],
    testCase "colima handles the bare 8Gi form" $
      colimaSizingArgs "demo" (Resources {cpu = 2, memory = "8Gi", storage = "20Gi"})
        @?= Right ["start", "--profile", "demo", "--cpu", "2", "--memory", "8", "--disk", "20"],
    testCase "applied Linux cordon targets the control-plane with budget caps" $
      kindNodeCordonArgs "demo-test-case1" demoResources
        @?= Right
          [ "update",
            "--cpus",
            "4",
            "--memory",
            show (8 * gib),
            "--memory-swap",
            show (8 * gib),
            "demo-test-case1-control-plane"
          ],
    testCase "the docker update cordon argv omits storage (no docker flag)" $
      assertBool "no storage in docker update argv" $
        case kindNodeCordonArgs "demo" demoResources of
          Right args -> show (20 * gib) `notElem` args
          Left _ -> False
  ]

leftHas :: String -> Either String a -> IO ()
leftHas needle e = case e of
  Left msg -> assertBool ("expected '" ++ needle ++ "' in: " ++ msg) (needle `isInfixOf` msg)
  Right _ -> assertBool ("expected Left mentioning " ++ needle) False

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
