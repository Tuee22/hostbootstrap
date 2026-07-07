module ReadinessSpec (tests) where

import HostBootstrap.Readiness
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ReadinessSpec"
    [ testGroup "named policies keep their historical budgets" policyCases,
      testGroup "pollStep (the pure decision)" pollStepCases,
      testGroup "drivePure (mocked probe sequence)" driveCases
    ]

policyCases :: [TestTree]
policyCases =
  [ testCase "each policy reproduces the loop budget it replaces" $ do
      (ppAttempts rolloutPoll, ppDelay rolloutPoll) @?= (6, seconds 5)
      (ppAttempts pushPoll, ppDelay pushPoll) @?= (4, seconds 5)
      (ppAttempts reachPoll, ppDelay reachPoll) @?= (24, seconds 5)
      (ppAttempts vmBootPoll, ppDelay vmBootPoll) @?= (60, seconds 2)
      (ppAttempts networkPoll, ppDelay networkPoll) @?= (20, seconds 3)
      (ppAttempts dockerPoll, ppDelay dockerPoll) @?= (30, seconds 2)
      (ppAttempts nodePoll, ppDelay nodePoll) @?= (10, seconds 3),
    testCase "withAttempts overrides only the budget (the 6/12/60 reach sites)" $ do
      ppAttempts (reachPoll `withAttempts` 12) @?= 12
      ppDelay (reachPoll `withAttempts` 12) @?= seconds 5,
    testCase "pollSchedule is (attempts - 1) gaps of the delay" $ do
      pollSchedule rolloutPoll @?= replicate 5 (seconds 5)
      pollSchedule (PollPolicy 1 (seconds 5)) @?= []
  ]

pollStepCases :: [TestTree]
pollStepCases =
  [ testCase "ProbeReady yields the payload immediately" $
      pollStep rolloutPoll "l" 0 (ProbeReady 'x') @?= Yield 'x',
    testCase "NotReady before the budget retries with the delay" $
      pollStep rolloutPoll "l" 0 (NotReady :: ProbeResult ()) @?= Retry (seconds 5),
    testCase "NotReady at the last attempt gives up with a timeout" $
      pollStep rolloutPoll "l" 5 (NotReady :: ProbeResult ()) @?= GiveUp (PollTimeout "l"),
    testCase "Failed gives up immediately, prefixed with the label (fail-fast)" $
      pollStep rolloutPoll "l" 0 (Failed "boom" :: ProbeResult ()) @?= GiveUp (PollFailed "l: boom")
  ]

driveCases :: [TestTree]
driveCases =
  [ testCase "converges on the first ProbeReady, recording the elapsed delays" $
      drivePure rolloutPoll "l" [NotReady, NotReady, ProbeReady (42 :: Int)]
        @?= (Right 42, [seconds 5, seconds 5]),
    testCase "exhausts the budget into a timeout (5 gaps for 6 attempts)" $
      drivePure rolloutPoll "l" (replicate 6 (NotReady :: ProbeResult ()))
        @?= (Left (PollTimeout "l"), replicate 5 (seconds 5)),
    testCase "a Failed verdict beats the remaining budget (fail-fast)" $
      drivePure pushPoll "l" [NotReady, Failed "nope" :: ProbeResult ()]
        @?= (Left (PollFailed "l: nope"), [seconds 5])
  ]
