module LifecycleSpec (tests) where

import Data.List (isInfixOf)
import HostBootstrap.Cluster.Lifecycle
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

prod :: ClusterPlan
prod = resolvePlan "demo" "/srv/demo" Production

test1 :: ClusterPlan
test1 = resolvePlan "demo" "/srv/demo" (TestCase "case1")

tests :: TestTree
tests =
  testGroup
    "LifecycleSpec"
    [ testGroup "resolvePlan" planCases,
      testGroup "profiles are distinct" profileCases,
      testGroup "host-port publication" hostPortCases,
      testGroup "never-delete-.data" dataInvariantCases,
      testGroup "status report" statusCases
    ]

planCases :: [TestTree]
planCases =
  [ testCase "production: fixed name and .data path" $ do
      clusterName prod @?= "demo"
      dataPath prod @?= "/srv/demo/.data"
      derivedPaths prod @?= ["/srv/demo/.cluster/demo"],
    testCase "test: per-case isolated name and path" $ do
      clusterName test1 @?= "demo-test-case1"
      dataPath test1 @?= "/srv/demo/.test_data/case1"
      derivedPaths test1 @?= ["/srv/demo/.cluster/demo-test-case1"]
  ]

hostPortCases :: [TestTree]
hostPortCases =
  [ testCase "production publishes the host NodePorts (kind.yaml)" $
      publishesHostPorts prod @?= True,
    testCase "test cluster binds no host port so cases never collide" $
      publishesHostPorts test1 @?= False
  ]

profileCases :: [TestTree]
profileCases =
  [ testCase "production and test resolve distinct cluster names" $
      assertBool "names differ" (clusterName prod /= clusterName test1),
    testCase "production and test resolve distinct host data paths" $
      assertBool "data paths differ" (dataPath prod /= dataPath test1)
  ]

dataInvariantCases :: [TestTree]
dataInvariantCases =
  [ testCase "down removes nothing on disk and preserves .data" $ do
      let (remove, preserve) = teardown Down prod
      remove @?= []
      assertBool ".data preserved" (dataPath prod `elem` preserve),
    testCase "delete removes derived state but never .data" $ do
      let (remove, preserve) = teardown Delete prod
      assertBool ".data not in removal set" (dataPath prod `notElem` remove)
      assertBool "derived state removed" (derivedPaths prod == remove)
      assertBool ".data preserved" (dataPath prod `elem` preserve),
    testCase "test profile also never deletes its .data" $ do
      let (removeDown, _) = teardown Down test1
          (removeDel, _) = teardown Delete test1
      assertBool "down keeps test .data" (dataPath test1 `notElem` removeDown)
      assertBool "delete keeps test .data" (dataPath test1 `notElem` removeDel)
  ]

statusCases :: [TestTree]
statusCases =
  [ testCase "running cluster reports (running) and preserves .data" $ do
      let report = statusReport prod True
      assertBool "names the cluster" ("demo" `isInfixOf` report)
      assertBool "marks it running" ("(running)" `isInfixOf` report)
      assertBool "shows preserved .data" ("/srv/demo/.data (preserved)" `isInfixOf` report),
    testCase "absent cluster reports (absent), still preserving .data" $ do
      let report = statusReport prod False
      assertBool "marks it absent" ("(absent)" `isInfixOf` report)
      assertBool "still preserves .data" ("(preserved)" `isInfixOf` report)
  ]
