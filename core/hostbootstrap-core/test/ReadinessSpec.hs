{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module ReadinessSpec (tests) where

import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Readiness
import HostBootstrap.Reconcile
  ( LifecyclePlan,
    PlannedResource,
    PlannedResourceKind (ProviderResourceKind),
    ProviderResource,
    withLifecyclePlan,
    withPlannedResourceOfKind,
  )
import HostBootstrap.Step (StepFrame (StepFrame), StepObservation (StepChanged), StepPlan, deployVMStep, mkStepPlan)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ReadinessSpec"
    [ testGroup "validated policies" policyCases,
      testGroup "total pollStep" pollStepCases,
      testGroup "pure driver" driveCases,
      testCase "indexed readiness retains backend versions" indexedReadinessCase,
      testCase "indexed probes reject zero backend versions" invalidIndexedProbeCase
    ]

fiveSeconds :: Micros
fiveSeconds = rightOrFail (seconds 5)

policyCases :: [TestTree]
policyCases =
  [ testCase "named policies preserve their budgets" $ do
      (pollAttempts rolloutPoll, pollDelay rolloutPoll) @?= (6, fiveSeconds)
      (pollAttempts pushPoll, pollDelay pushPoll) @?= (4, fiveSeconds)
      (pollAttempts reachPoll, pollDelay reachPoll) @?= (24, fiveSeconds)
      pollAttempts vmBootPoll @?= 60
      pollAttempts networkPoll @?= 20
      pollAttempts dockerPoll @?= 30
      pollAttempts nodePoll @?= 10,
    testCase "attempt override is validated and preserves delay" $ do
      let adjusted = withAttempts reachPoll 12
      fmap pollAttempts adjusted @?= Right 12
      fmap pollDelay adjusted @?= Right fiveSeconds,
    testCase "schedule contains attempts minus one gaps" $ do
      pollSchedule rolloutPoll @?= replicate 5 fiveSeconds
      one <- pure (mkPollPolicy 1 fiveSeconds)
      fmap pollSchedule one @?= Right [],
    testCase "zero/negative/overflow/over-limit policies are rejected" $ do
      mkPollPolicy 0 fiveSeconds @?= Left ZeroAttempts
      seconds (-1) @?= Left (NegativeDelay (-1))
      assertBool "overflowing delay rejected" (isLeft (seconds (toInteger (maxBound :: Int))))
      assertBool "duration above the command limit rejected" $
        isLeft (seconds (24 * 60 * 60 + 1) >>= mkPollPolicy 2)
  ]

pollStepCases :: [TestTree]
pollStepCases =
  [ testCase "ready yields immediately" $
      pollStep rolloutPoll "l" 0 (ProbeReady 'x') @?= Yield 'x',
    testCase "transient not-ready retries" $
      pollStep rolloutPoll "l" 0 (NotReady "starting" :: ProbeResult ())
        @?= Retry fiveSeconds,
    testCase "last transient result times out with observation" $
      pollStep rolloutPoll "l" 5 (NotReady "starting" :: ProbeResult ())
        @?= GiveUp (PollTimeout "l" "starting"),
    testCase "unavailable stops immediately" $
      pollStep rolloutPoll "l" 0 (Unavailable "wrong substrate" :: ProbeResult ())
        @?= GiveUp (PollUnavailable "l" "wrong substrate"),
    testCase "conflict stops immediately with structure" $
      let conflict = ProbeConflict "generation-1" "generation-2" "remove the foreign resource"
       in pollStep rolloutPoll "l" 0 (ProbeConflicted conflict :: ProbeResult ())
            @?= GiveUp (PollConflict "l" conflict),
    testCase "deterministic failure stops immediately" $
      let failure = ProbeFailure "docker info" "permission denied"
       in pollStep rolloutPoll "l" 0 (Failed failure :: ProbeResult ())
            @?= GiveUp (PollFailed "l" failure)
  ]

driveCases :: [TestTree]
driveCases =
  [ testCase "converges and records elapsed delays" $
      drivePure rolloutPoll "l" [NotReady "a", NotReady "b", ProbeReady (42 :: Int)]
        @?= (Right 42, [fiveSeconds, fiveSeconds]),
    testCase "exhausts the budget" $
      drivePure rolloutPoll "l" (replicate 6 (NotReady "starting" :: ProbeResult ()))
        @?= (Left (PollTimeout "l" "starting"), replicate 5 fiveSeconds),
    testCase "failure beats remaining budget" $
      let failure = ProbeFailure "probe" "nope"
       in drivePure pushPoll "l" [NotReady "starting", Failed failure :: ProbeResult ()]
            @?= (Left (PollFailed "l" failure), [fiveSeconds])
  ]

indexedReadinessCase :: IO ()
indexedReadinessCase =
  runPlannedProbe $ \planned ->
    case
      withBackendProbe
        ProviderRespondingProbe
        planned
        7
        11
        13
        (const (pure (ProbeReady ())))
        ( \probe -> do
            result <-
              awaitPlanReady
                rolloutPoll
                "provider"
                probe
                (error "the injected probe does not inspect HostConfig" :: HostConfig)
            case result of
              Left err -> assertBool ("expected readiness, got " ++ renderPollError err) False
              Right ready ->
                ( readyGeneration ready,
                  readyPhaseVersion ready,
                  readyObservationVersion ready
                )
                  @?= (7, 11, 13 :: Word64)
        ) of
      Left err -> assertBool ("expected valid indexed probe, got " ++ show err) False
      Right assertion -> assertion

invalidIndexedProbeCase :: IO ()
invalidIndexedProbeCase =
  runPlannedProbe $ \planned ->
    case
      withBackendProbe
        ProviderRespondingProbe
        planned
        0
        1
        1
        (const (pure (ProbeReady ())))
        (const ()) of
      Left ZeroProbeGeneration -> pure ()
      other -> assertBool ("expected zero-generation rejection, got " ++ show other) False

rightOrFail :: Show e => Either e a -> a
rightOrFail = either (error . show) id

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

testPlan :: StepPlan
testPlan =
  either
    (error . show)
    id
    (mkStepPlan [deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged))])

withTestLifecyclePlan ::
  (forall planId. LifecyclePlan (Production Fixture.FixtureProject) planId -> result) ->
  result
withTestLifecyclePlan consume =
  withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
    withLifecyclePlan codec testPlan consume

runPlannedProbe ::
  ( forall planId id frame.
    PlannedResource
      (Production Fixture.FixtureProject)
      planId
      id
      ProviderResource
      frame ->
    IO ()
  ) ->
  IO ()
runPlannedProbe consume =
  case
    withTestLifecyclePlan $ \plan ->
      withPlannedResourceOfKind plan ProviderResourceKind "core:deploy-vm" consume of
    Left err -> assertBool ("expected planned resource, got " ++ show err) False
    Right assertion -> assertion
