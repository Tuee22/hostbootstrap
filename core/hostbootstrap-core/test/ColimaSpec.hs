{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ColimaSpec (tests) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as Text
import qualified Fixture
import HostBootstrap.Cluster.Budget
import HostBootstrap.Cluster.Cordon
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Ensure.Colima
import HostBootstrap.Lift (localContext)
import HostBootstrap.ProjectPlan
  ( ClusterResource,
    PlannedResource,
    PlannedResourceKind (ClusterResourceKind, ProviderResourceKind),
    ProjectPlan,
    ProviderResource,
    forward,
    plannedStepOperationKey,
    withPlannedResourceOfKind,
  )
import HostBootstrap.Reconcile (lifecyclePlanFromProjectPlan)
import HostBootstrap.Step
  ( StepFrame (StepFrame),
    StepObservation (StepChanged),
    StepPlan,
    deployKindStep,
    deployVMStep,
    descendsVia,
    mkStepPlan,
  )
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
    [ testCase "prepared project wall uses a named exact profile and current Colima flags" $ do
        result <- preparedSummary "demo"
        result
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
      testCase "Docker operations route through the named context without global activation" $ do
        result <- dockerArgsSummary "demo" ["info"]
        result @?= Right ["--context", "colima-demo", "info"],
      testCase "the mutable shared default profile is rejected" $ do
        result <- preparedSummary "default"
        assertBool "default must not mint a project profile" (isLeft result),
      testCase "two project identities derive disjoint profiles" $ do
        projectA <- preparedSummary "project-a"
        projectB <- preparedSummary "project-b"
        fmap (\(name, contextName, _) -> (name, contextName)) projectA
          @?= Right ("project-a", "colima-project-a")
        fmap (\(name, contextName, _) -> (name, contextName)) projectB
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
        absent <- decisionFor []
        running <- decisionFor [exactInstance "Running"]
        stopped <- decisionFor [exactInstance "Stopped"]
        absent @?= Right CreateColimaWall
        running @?= Right KeepExactColimaWall
        stopped @?= Right StartStoppedColimaWall,
      testCase "an incompatible same-name wall is a structured refusal" $ do
        result <- decisionFor [ColimaInstance "demo" "Running" 4 (16 * gib) (100 * gib) "docker"]
        case result of
          Right (RefuseColimaWall _) -> pure ()
          other -> assertBool ("expected refusal, got " ++ show other) False,
      testCase "a non-Docker same-name profile is never adopted" $ do
        result <- decisionFor [(exactInstance "Running"){ciRuntime = "incus"}]
        case result of
          Right (RefuseColimaWall _) -> pure ()
          other -> assertBool ("expected refusal, got " ++ show other) False,
      testCase "malformed provider output fails as data" $
        assertBool "invalid JSON must fail" (isLeft (parseColimaInstances "{not-json}"))
    ]

exactInstance :: String -> ColimaInstance
exactInstance status =
  ColimaInstance "demo" status 8 (16 * gib) (100 * gib) "docker"

preparedSummary :: String -> IO (Either String (String, String, [String]))
preparedSummary projectName =
  withPreparedTestCall projectName $ \profile call ->
    ( colimaProfileName profile,
      colimaDockerContext profile,
      preparedColimaWallArgs call
    )

dockerArgsSummary :: String -> [String] -> IO (Either String [String])
dockerArgsSummary projectName args =
  withPreparedTestCall projectName $ \profile _ ->
    colimaDockerArgs profile args

decisionFor :: [ColimaInstance] -> IO (Either String ColimaWallDecision)
decisionFor instances =
  fmap
    (>>= id)
    ( withPreparedTestCall "demo"
        (\_ call -> first show (classifyColimaWall call instances))
    )

withPreparedTestCall ::
  String ->
  ( forall
      projectId
      planId
      budgetId
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence
      profileId.
    ColimaProfile (Production projectId) planId profileId ->
    PreparedColimaWallCall
      (Production projectId)
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
  IO (Either String result)
withPreparedTestCall projectName consume =
  withTestProjectResources $ \plan providerResource clusterResource ->
    pure $ do
      workload <- first show (mkWorkload clusterResource 1 1 gib gib)
      overhead <- first show (mkResourceBudget 1 gib gib)
      sliceBudget <- first show (mkResourceBudget 6 (10 * gib) (80 * gib))
      minimumBudget <- first show (mkResourceBudget 1 gib gib)
      request <- first show (mkSliceRequest providerResource sliceBudget minimumBudget)
      let context =
            Context.contextForKind
              (fromString projectName)
              (fromString projectName)
              "."
              Context.HostOrchestrator
          compatibilityPlan = lifecyclePlanFromProjectPlan plan
      profiled <-
        first show $
          withColimaProfile compatibilityPlan context $ \profile ->
            flattenBudget $
              withValidatedBudget plan exactEnvelope $ \validated ->
                withProviderBudgetCapability plan providerResource ColimaProviderKey $ \capability ->
                  flattenBudget $
                    admitProviderBudget validated capability $ \wall effective ->
                      flattenBudget $
                        withPlannedWorkloadSet plan [workload] $ \workloads -> do
                          fit <- first show (verifyPlannedWorkloadFit effective workloads)
                          flattenBudget $
                            withBudgetPartition effective fit overhead (request :| []) $ \partition _ ->
                              flattenBudget $
                                withProviderWallReservation wall partition 1 $ \reservation ->
                                  consume profile
                                    <$> first show
                                      (prepareColimaWallCall profile wall partition reservation)
      profiled

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
    ( mkStepPlan
        [ descendsVia
            localContext
            (deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged))),
          deployKindStep "cluster" (StepFrame "provider" "Provider") (const (pure StepChanged))
        ]
    )

withTestProjectResources ::
  ( forall projectId specDigest planId configId providerId providerFrame clusterId clusterFrame.
    ProjectPlan
      (Production projectId)
      specDigest
      planId
      configId
      Fixture.ProjectConfig ->
    PlannedResource
      (Production projectId)
      planId
      providerId
      ProviderResource
      providerFrame ->
    PlannedResource
      (Production projectId)
      planId
      clusterId
      ClusterResource
      clusterFrame ->
    IO result
  ) ->
  IO result
withTestProjectResources consume =
  Fixture.withFixtureProjectPlan testPlan $ \plan ->
    case NonEmpty.toList (forward plan) of
      [providerNode, clusterNode] ->
        case
          withPlannedResourceOfKind
            plan
            ProviderResourceKind
            (plannedStepOperationKey providerNode)
            ( \providerResource ->
                withPlannedResourceOfKind
                  plan
                  ClusterResourceKind
                  (plannedStepOperationKey clusterNode)
                  (consume plan providerResource)
            ) of
          Left failure -> fail ("provider projection failed: " ++ show failure)
          Right (Left failure) -> fail ("cluster projection failed: " ++ show failure)
          Right (Right action) -> action
      nodes -> fail ("expected provider and cluster plan nodes, got " ++ show (length nodes))
