{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module ColimaSpec (tests) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Text as Text
import qualified Fixture
import HostBootstrap.Cluster.Budget
import HostBootstrap.Cluster.Cordon
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Ensure.Colima
import HostBootstrap.Reconcile (LifecyclePlan, withLifecyclePlan)
import HostBootstrap.Step (StepFrame (StepFrame), StepPlan, contextInitStep, mkStepPlan)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

gib :: Integer
gib = 1024 ^ (3 :: Integer)

exactEnvelope :: Context.ResourceEnvelope
exactEnvelope = Context.ResourceEnvelope 8 "16GiB" "100GiB"

tests :: TestTree
tests =
  testGroup
    "ColimaSpec"
    [ testCase "prepared project wall uses a named exact profile and current Colima flags" $
        preparedSummary "demo"
          @?= Right
            ( "demo",
              "colima-demo",
              [ "start",
                "--profile",
                "demo",
                "--runtime",
                "docker",
                "--activate=false",
                "--cpus",
                "8",
                "--memory",
                "16",
                "--disk",
                "100"
              ]
            ),
      testCase "Docker operations route through the named context without global activation" $
        dockerArgsSummary "demo" ["info"]
          @?= Right ["--context", "colima-demo", "info"],
      testCase "the mutable shared default profile is rejected" $
        assertBool "default must not mint a project profile" (isLeft (preparedSummary "default")),
      testCase "two project identities derive disjoint profiles" $ do
        fmap (\(name, contextName, _) -> (name, contextName)) (preparedSummary "project-a")
          @?= Right ("project-a", "colima-project-a")
        fmap (\(name, contextName, _) -> (name, contextName)) (preparedSummary "project-b")
          @?= Right ("project-b", "colima-project-b"),
      testCase "Colima JSONL observations retain exact resource walls" $
        parseColimaInstances
          ( unlines
              [ "{\"name\":\"demo\",\"status\":\"Running\",\"arch\":\"aarch64\",\"cpus\":8,\"memory\":17179869184,\"disk\":107374182400,\"runtime\":\"docker\"}",
                "{\"name\":\"other\",\"status\":\"Stopped\",\"arch\":\"aarch64\",\"cpus\":2,\"memory\":2147483648,\"disk\":107374182400,\"runtime\":\"incus\"}"
              ]
          )
          @?= Right
            [ ColimaInstance "demo" "Running" 8 (16 * gib) (100 * gib) "docker",
              ColimaInstance "other" "Stopped" 2 (2 * gib) (100 * gib) "incus"
            ],
      testCase "absent/exact-running/exact-stopped walls classify without mutation ambiguity" $ do
        decisionFor [] @?= Right CreateColimaWall
        decisionFor [exactInstance "Running"] @?= Right KeepExactColimaWall
        decisionFor [exactInstance "Stopped"] @?= Right StartStoppedColimaWall,
      testCase "an incompatible same-name wall is a structured refusal" $ do
        result <- pure (decisionFor [ColimaInstance "demo" "Running" 4 (16 * gib) (100 * gib) "docker"])
        case result of
          Right (RefuseColimaWall _) -> pure ()
          other -> assertBool ("expected refusal, got " ++ show other) False,
      testCase "a non-Docker same-name profile is never adopted" $ do
        result <- pure (decisionFor [(exactInstance "Running"){ciRuntime = "incus"}])
        case result of
          Right (RefuseColimaWall _) -> pure ()
          other -> assertBool ("expected refusal, got " ++ show other) False,
      testCase "malformed provider output fails as data" $
        assertBool "invalid JSON must fail" (isLeft (parseColimaInstances "{not-json}"))
    ]

exactInstance :: String -> ColimaInstance
exactInstance status =
  ColimaInstance "demo" status 8 (16 * gib) (100 * gib) "docker"

preparedSummary :: String -> Either String (String, String, [String])
preparedSummary projectName =
  withPreparedTestCall projectName $ \profile call ->
    ( colimaProfileName profile,
      colimaDockerContext profile,
      preparedColimaWallArgs call
    )

dockerArgsSummary :: String -> [String] -> Either String [String]
dockerArgsSummary projectName args =
  withPreparedTestCall projectName $ \profile _ ->
    colimaDockerArgs profile args

decisionFor :: [ColimaInstance] -> Either String ColimaWallDecision
decisionFor instances =
  withPreparedTestCall "demo"
    (\_ call -> first show (classifyColimaWall call instances))
    >>= id

withPreparedTestCall ::
  String ->
  ( forall
      planId
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence
      profileId.
    ColimaProfile (Production Fixture.FixtureProject) planId profileId ->
    PreparedColimaWallCall
      (Production Fixture.FixtureProject)
      planId
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence
      profileId ->
    result
  ) ->
  Either String result
withPreparedTestCall projectName consume = do
  workload <- first show (mkWorkload "project" 1 1 gib gib)
  overhead <- first show (mkResourceBudget 1 gib gib)
  sliceBudget <- first show (mkResourceBudget 6 (10 * gib) (80 * gib))
  minimumBudget <- first show (mkResourceBudget 1 gib gib)
  request <- first show (mkSliceRequest "project-vm" "metal" sliceBudget minimumBudget)
  withTestLifecyclePlan $ \plan ->
    let context =
          Context.contextForKind
            (fromString projectName)
            (fromString projectName)
            "."
            Context.HostOrchestrator
     in case withColimaProfile plan context $ \profile ->
          flattenBudget $
            withValidatedBudget plan exactEnvelope $ \validated ->
              withProviderBudgetCapability plan ColimaProviderKey $ \capability ->
                flattenBudget $
                  admitProviderBudget validated capability $ \wall effective ->
                    flattenBudget $
                      withPlannedWorkloadSet [workload] $ \workloads -> do
                        fit <- first show (verifyPlannedWorkloadFit effective workloads)
                        flattenBudget $
                          withBudgetPartition effective fit overhead (request :| []) $ \partition _ ->
                            flattenBudget $
                              withProviderWallReservation wall partition 1 $ \reservation ->
                                consume profile
                                  <$> first show
                                    (prepareColimaWallCall profile wall partition reservation)
        of
          Left err -> Left (show err)
          Right result -> result

fromString :: String -> Text.Text
fromString = Text.pack

flattenBudget :: Either BudgetError (Either String a) -> Either String a
flattenBudget = either (Left . show) id

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

testPlan :: StepPlan
testPlan =
  either
    (error . show)
    id
    (mkStepPlan [contextInitStep "context" (StepFrame "host" "Host") (const (pure ()))])

withTestLifecyclePlan ::
  (forall planId. LifecyclePlan (Production Fixture.FixtureProject) planId -> result) ->
  result
withTestLifecyclePlan consume =
  withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
    withLifecyclePlan codec testPlan consume
