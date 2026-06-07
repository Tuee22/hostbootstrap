{-# LANGUAGE OverloadedStrings #-}

module CordonSpec (tests) where

import Data.List (isInfixOf)
import HostBootstrap.Cluster.Cordon
import HostBootstrap.Config.Schema (Resources (..))
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
      testGroup "sizing" sizingCases
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

sizingCases :: [TestTree]
sizingCases =
  [ testCase "colima sizing reflects the budget" $
      colimaSizingArgs demoResources
        @?= Right ["start", "--cpu", "4", "--memory", "8", "--disk", "20"],
    testCase "kind node limits reflect the budget" $
      kindNodeLimits demoResources
        @?= Right [("cpus", "4"), ("memory", show (8 * gib)), ("storage", show (20 * gib))]
  ]

leftHas :: String -> Either String a -> IO ()
leftHas needle e = case e of
  Left msg -> assertBool ("expected '" ++ needle ++ "' in: " ++ msg) (needle `isInfixOf` msg)
  Right _ -> assertBool ("expected Left mentioning " ++ needle) False

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
