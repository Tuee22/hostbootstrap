{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

{- | The verb-indexed reverse projection and its teardown forest (the recursive-lifecycle-command phase).

The plan under test is the demo's own shape: a metal frame that ensures the
provider (preserve-on-reverse) and launches the VM, a VM frame that builds, and
a container frame that stands up the cluster and the chart. That shape is what
makes the child-first and pre-descent properties observable rather than
hypothetical.
-}
module TeardownSpec (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Fixture
import HostBootstrap.HostConfig (HostConfig, buildHostConfig)
import HostBootstrap.Substrate (detect)
import System.IO.Unsafe (unsafePerformIO)
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Lift (localContext)
import HostBootstrap.Reconcile (LifecyclePlan, lifecyclePlanDigest, withLifecyclePlan)
import HostBootstrap.Step
import HostBootstrap.Teardown
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

type FixtureScope = Production Fixture.FixtureProject

tests :: TestTree
tests =
    testGroup
        "TeardownSpec"
        [ testGroup "the reverse projection" projectionTests
        , testGroup "driving the projection" projectionDriverTests
        , testGroup "the forest" forestTests
        , testGroup "settlement" settlementTests
        ]

-- ---------------------------------------------------------------------------
-- Projection

projectionTests :: [TestTree]
projectionTests =
    [ testCase "both verbs project the same identities, deepest frame first" $
        withPlan $ \plan -> do
            let down = teardownPlanStepKeys (teardownPlan plan downVerb)
                destroy = teardownPlanStepKeys (teardownPlan plan destroyVerb)
            down @?= destroy
            down
                @?= [ "core:deploy-chart"
                    , "core:deploy-kind"
                    , "core:build-pb"
                    , "core:deploy-vm"
                    ]
    , testCase "a preserve-on-reverse step is in neither projection" $
        withPlan $ \plan ->
            assertBool
                "the preserved provider-ensure step is absent"
                ( "project:ensure-vm-provider"
                    `notElem` teardownPlanStepKeys (teardownPlan plan destroyVerb)
                )
    , testCase "the provider is stopped by down and deleted by destroy" $
        withPlan $ \plan -> do
            lookup "core:deploy-vm" (teardownPlanActions (teardownPlan plan downVerb))
                @?= Just StopFrame
            lookup "core:deploy-vm" (teardownPlanActions (teardownPlan plan destroyVerb))
                @?= Just DeleteFrame
    , testCase "the kind cluster is deleted by both verbs, because kind has no stop" $
        withPlan $ \plan -> do
            lookup "core:deploy-kind" (teardownPlanActions (teardownPlan plan downVerb))
                @?= Just DeleteCluster
            lookup "core:deploy-kind" (teardownPlanActions (teardownPlan plan destroyVerb))
                @?= Just DeleteCluster
    , testCase "a plan whose every step preserves projects nothing and cannot open" $
        withPreservedPlan $ \plan ->
            case openTeardownForest plan (teardownPlan plan destroyVerb) of
                Left (TeardownPlanEmpty "destroy") -> pure ()
                other -> assertFailure ("expected an empty projection, got " ++ describeOpen other)
    ]

-- ---------------------------------------------------------------------------
-- The forest

forestTests :: [TestTree]
forestTests =
    [ testCase "destroy offers the provider's pre-descent step before any child" $
        withDestroyForest $ \forest ->
            firstWorkKey forest @?= "core:deploy-vm"
    , testCase "down never offers a pre-descent step" $
        withDownForest $ \forest ->
            -- The deepest frame's own step is first, because a down does not
            -- descend past a stopped provider.
            firstWorkKey forest @?= "core:deploy-chart"
    , testCase "the pre-descent step exposes the children, not the provider itself" $
        withDestroyForest $ \forest -> do
            let afterReach = attempt forest TeardownReleased
            firstWorkKey afterReach @?= "core:deploy-chart"
    , testCase "a parent is not offered until its exact child set settles" $
        withDestroyForest $ \forest -> do
            let order = drainOrder forest
            order
                @?= [ "core:deploy-vm" -- pre-descent reachability
                    , "core:deploy-chart"
                    , "core:deploy-kind"
                    , "core:build-pb"
                    , "core:deploy-vm" -- the ordinary delete, last
                    ]
    , testCase "the ordinary branch carries the settled-child proof" $
        withDestroyForest $ \forest -> do
            -- skip the pre-descent step, then settle both container-frame nodes
            let ready = drainUntil "core:deploy-vm" (attempt forest TeardownReleased)
            eliminateTeardownProgress
                (nextTeardownWork ready)
                (\_ -> assertFailure "the forest completed before the provider step")
                ( \point ->
                    withTeardownAuthorization
                        point
                        (\_ -> assertFailure "a second pre-descent step was offered")
                        ( \settled cursor -> do
                            teardownCursorAction cursor @?= DeleteFrame
                            settledChildrenKeys settled @?= ["core:build-pb"]
                        )
                )
    , testCase "a failed node blocks its parent but leaves siblings schedulable" $
        withDestroyForest $ \forest -> do
            let reached = attempt forest TeardownReleased
                failedChart = attempt reached (TeardownFailed "helm uninstall timed out")
            -- the sibling in the same frame is still offered
            firstWorkKey failedChart @?= "core:deploy-kind"
            let afterSibling = attempt failedChart TeardownReleased
            -- ... and the parent is NOT: the failed node is offered again
            -- instead, after every unrelated sibling has had its turn.
            eliminateTeardownProgress
                (nextTeardownWork afterSibling)
                (\_ -> assertFailure "a forest with a failed node must never complete")
                (\point -> authorizationPointKey point @?= "core:deploy-chart")
            teardownForestFailures failedChart
                @?= [("core:deploy-chart", "helm uninstall timed out")]
    , testCase "foreign and refused observations settle without being torn down" $
        withDestroyForest $ \forest -> do
            let reached = attempt forest TeardownReleased
                foreignChart = attempt reached (TeardownForeignRetained "an operator's release")
            teardownForestForeign foreignChart
                @?= [("core:deploy-chart", "an operator's release")]
            teardownForestFailures foreignChart @?= []
            -- it settled, so the frame continues rather than blocking
            firstWorkKey foreignChart @?= "core:deploy-kind"
    , testCase "every attempt returns a successor forest, including a failure" $
        withDestroyForest $ \forest -> do
            let reached = attempt forest TeardownReleased
                failed = attempt reached (TeardownFailed "boom")
            assertBool
                "the failed node is no longer outstanding as pending work"
                ("core:deploy-chart" `elem` teardownForestOutstanding failed)
            length (teardownForestOutstanding failed) @?= 4
    ]

-- ---------------------------------------------------------------------------
-- Settlement

{- | The reverse projection is what @project down@/@project destroy@ actually
run, so these prove the plan — not a hook beside it — supplies both the order
and the effects.
-}
projectionDriverTests :: [TestTree]
projectionDriverTests =
    [ testCase "each node runs the reverse its own step declared, deepest frame first" $
        withReversedPlan $ \plan observed -> do
            let projection = teardownPlan plan destroyVerb
            outcomes <- runTeardownProjection projection neverCore hostConfigFixture
            readIORef observed
                >>= ( @?=
                        [ ("core:deploy-chart", ReleaseResource)
                        , ("core:build-pb", ReleaseResource)
                        , ("core:deploy-vm", DeleteFrame)
                        ]
                    )
            -- Every attempted node, including the core-managed cluster the
            -- project declared no reverse for.
            [key | (key, Just _) <- outcomes]
                @?= ["core:deploy-chart", "core:deploy-kind", "core:build-pb", "core:deploy-vm"]
    , testCase "the verb reaches the declared effect: down stops, destroy deletes" $
        withReversedPlan $ \plan observed -> do
            _ <- runTeardownProjection (teardownPlan plan downVerb) neverCore hostConfigFixture
            seen <- readIORef observed
            lookup "core:deploy-vm" seen @?= Just StopFrame
    , testCase "a node that declared no reverse is skipped, not silently released" $
        withReversedPlan $ \plan _ -> do
            outcomes <- runTeardownProjection (teardownPlan plan destroyVerb) neverCore hostConfigFixture
            lookup "core:deploy-kind" outcomes @?= Just (Just coreHandled)
            -- `copy-source` declares neither a reverse nor core management.
            lookup "core:copy-source" outcomes @?= Just Nothing
    , -- The core adapter must be able to tell the cluster apart from the
      -- core-managed resources that live *inside* it, or it would run the
      -- cluster teardown once per node. The action is what carries that.
      testCase "the core adapter receives each node's own action" $
        withReversedPlan $ \plan _ -> do
            seen <- newIORef []
            let recordCore key coreAction = do
                    modifyIORef' seen (++ [(key, coreAction)])
                    pure TeardownReleased
            _ <- runTeardownProjection (teardownPlan plan destroyVerb) recordCore hostConfigFixture
            readIORef seen >>= (@?= [("core:deploy-kind", DeleteCluster)])
    , testCase "a throwing reverse becomes a failure and later nodes still run" $
        withThrowingPlan $ \plan reached -> do
            outcomes <- runTeardownProjection (teardownPlan plan destroyVerb) neverCore hostConfigFixture
            case lookup "core:build-pb" outcomes of
                Just (Just (TeardownFailed _)) -> pure ()
                other -> assertFailure ("expected a captured failure, got " ++ show other)
            readIORef reached >>= (@?= True)
    ]
  where
    coreHandled = TeardownForeignRetained "core adapter"
    neverCore _key _action = pure coreHandled

settlementTests :: [TestTree]
settlementTests =
    [ testCase "a completed destroy forest settles every projected identity" $
        withPlan $ \plan -> do
            let projection = teardownPlan plan destroyVerb
            forest <- openOrFail plan projection
            completed <- drainToCompletion forest
            case verifyDestroySettled projection completed of
                Right settled -> do
                    destroySettledPlanDigest settled @?= planDigestOf plan
                    assertBool
                        "every projected identity is released"
                        ( all
                            (`elem` destroySettledReleasedKeys settled)
                            (teardownPlanStepKeys projection)
                        )
                Left failure -> assertFailure (teardownErrorMessage failure)
    , testCase "a node that keeps failing keeps the forest from ever completing" $
        withDestroyForest $ \forest -> do
            let reached = attempt forest TeardownReleased
                -- every attempt on the chart fails; everything else releases
                stuck = drainFailing "core:deploy-chart" reached
            eliminateTeardownProgress
                (nextTeardownWork stuck)
                (\_ -> assertFailure "a forest with a failing descendant must not complete")
                (\point -> authorizationPointKey point @?= "core:deploy-chart")
            teardownForestFailures stuck @?= [("core:deploy-chart", "boom")]
            assertBool
                "the blocked parent chain is still outstanding"
                ( all
                    (`elem` teardownForestOutstanding stuck)
                    ["core:deploy-chart", "core:build-pb", "core:deploy-vm"]
                )
    , testCase "a truncated traversal cannot be presented as a settled destroy" $
        withPlan $ \plan -> do
            let projection = teardownPlan plan destroyVerb
            forest <- openOrFail plan projection
            -- settle only the pre-descent step and the two container-frame nodes
            let partial = drainUntil "core:build-pb" (attempt forest TeardownReleased)
            case nextTeardownWork partial of
                progress ->
                    eliminateTeardownProgress
                        progress
                        ( \completed -> case verifyDestroySettled projection completed of
                            Left (TeardownIncomplete missing) ->
                                assertFailure ("unexpectedly completed early, missing " ++ show missing)
                            _ -> assertFailure "the forest completed before every node settled"
                        )
                        (\point -> authorizationPointKey point @?= "core:build-pb")
    ]

-- ---------------------------------------------------------------------------
-- Driving the forest

attempt ::
    TeardownForest scope planId verb -> TeardownOutcome -> TeardownForest scope planId verb
attempt forest outcome =
    eliminateTeardownProgress
        (nextTeardownWork forest)
        (const forest)
        (\point -> attemptTeardownStep point outcome)

firstWorkKey :: TeardownForest scope planId verb -> Text
firstWorkKey forest =
    eliminateTeardownProgress
        (nextTeardownWork forest)
        (const "<completed>")
        authorizationPointKey

-- | Release every offered step, recording the order they were offered in.
drainOrder :: TeardownForest scope planId verb -> [Text]
drainOrder = go (0 :: Int)
  where
    go depth forest
        | depth > 32 = ["<runaway>"]
        | otherwise =
            eliminateTeardownProgress
                (nextTeardownWork forest)
                (const [])
                ( \point ->
                    authorizationPointKey point
                        : go (depth + 1) (attemptTeardownStep point TeardownReleased)
                )

-- | Release steps until the next offered step is the named one.
drainUntil :: Text -> TeardownForest scope planId verb -> TeardownForest scope planId verb
drainUntil target = go (0 :: Int)
  where
    go depth forest
        | depth > 32 = forest
        | firstWorkKey forest == target = forest
        | otherwise = go (depth + 1) (attempt forest TeardownReleased)

{- | Drive to a fixed point, failing every attempt on the named key and
releasing every other. Bounded, because a permanently failing node is
deliberately re-offered forever.
-}
drainFailing :: Text -> TeardownForest scope planId verb -> TeardownForest scope planId verb
drainFailing target = go (0 :: Int)
  where
    go depth forest
        | depth > 16 = forest
        | otherwise =
            eliminateTeardownProgress
                (nextTeardownWork forest)
                (const forest)
                ( \point ->
                    if authorizationPointKey point == target
                        then go (depth + 1) (attemptTeardownStep point (TeardownFailed "boom"))
                        else go (depth + 1) (attemptTeardownStep point TeardownReleased)
                )

-- | Release everything still offered.
drainAll :: TeardownForest scope planId verb -> TeardownForest scope planId verb
drainAll = go (0 :: Int)
  where
    go depth forest
        | depth > 32 = forest
        | otherwise =
            eliminateTeardownProgress
                (nextTeardownWork forest)
                (const forest)
                (\point -> go (depth + 1) (attemptTeardownStep point TeardownReleased))

drainToCompletion ::
    TeardownForest scope planId verb -> IO (CompletedTeardownForest scope planId verb)
drainToCompletion forest =
    eliminateTeardownProgress
        (nextTeardownWork (drainAll forest))
        pure
        ( \point ->
            assertFailure
                ("the forest did not complete; still offering " ++ show (authorizationPointKey point))
        )

{- | The demo shape again, but with reverse effects attached to the nodes that
acquire something, exactly as a project declares them. @copy-source@
deliberately declares none, and @deploy-kind@ is core-managed.
-}
withReversedPlan ::
    ( forall planId.
      LifecyclePlan FixtureScope planId ->
      IORef [(Text, TeardownAction)] ->
      IO result
    ) ->
    IO result
withReversedPlan consume = do
    observed <- newIORef []
    let record key _cfg action = do
            modifyIORef' observed (++ [(key, action)])
            pure TeardownReleased
        plan =
            mkPlan
                [ projectStep (demoStep "ensure-vm-provider") PreserveOnReverse "ensure" metalFrame noop
                , reversedBy
                    (record "core:deploy-vm")
                    (descendsVia localContext (deployVMStep "launch" metalFrame noop))
                , copySourceStep "stage" metalFrame noop
                , reversedBy
                    (record "core:build-pb")
                    (descendsVia localContext (buildPbStep "build" vmFrame noop))
                , deployKindStep "cluster" containerFrame noop
                , reversedBy
                    (record "core:deploy-chart")
                    (deployChartStep "chart" containerFrame noop)
                ]
    withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
        withLifecyclePlan codec plan (\lifecycle -> consume lifecycle observed)

-- | A plan whose @build-pb@ reverse throws, with a later node that must still run.
withThrowingPlan ::
    (forall planId. LifecyclePlan FixtureScope planId -> IORef Bool -> IO result) ->
    IO result
withThrowingPlan consume = do
    reached <- newIORef False
    let plan =
            mkPlan
                [ reversedBy
                    (\_cfg _action -> writeIORef reached True >> pure TeardownReleased)
                    (descendsVia localContext (deployVMStep "launch" metalFrame noop))
                , reversedBy
                    (\_cfg _action -> ioError (userError "boom"))
                    (buildPbStep "build" vmFrame noop)
                ]
    withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
        withLifecyclePlan codec plan (\lifecycle -> consume lifecycle reached)

{- | A real 'HostConfig' for the host the suite runs on. The reverse effects
under test never touch a tool, so its resolved set is irrelevant; what matters
is that the driver threads the production value rather than a stub.
-}
hostConfigFixture :: HostConfig
hostConfigFixture = unsafePerformIO (detect >>= either fail pure >>= buildHostConfig)
{-# NOINLINE hostConfigFixture #-}

-- ---------------------------------------------------------------------------
-- Plans

{- | The demo's own shape: an ensure step that preserves on reverse, the VM
launch, the in-VM build, and the in-container cluster and chart.
-}
demoShapedPlan :: StepPlan
demoShapedPlan =
    mkPlan
        [ projectStep (demoStep "ensure-vm-provider") PreserveOnReverse "ensure" metalFrame noop
        , descendsVia localContext (deployVMStep "launch" metalFrame noop)
        , descendsVia localContext (buildPbStep "build" vmFrame noop)
        , deployKindStep "cluster" containerFrame noop
        , deployChartStep "chart" containerFrame noop
        ]

allPreservedPlan :: StepPlan
allPreservedPlan =
    mkPlan
        [ projectStep (demoStep "ensure-vm-provider") PreserveOnReverse "ensure" metalFrame noop
        ]

mkPlan :: [Step] -> StepPlan
mkPlan = either (error . show) id . mkStepPlan

demoStep :: String -> ProjectStepId
demoStep = either (error . show) id . projectStepId

noop :: p -> IO StepObservation
noop _ = pure StepChanged

metalFrame :: StepFrame
metalFrame = StepFrame "host-orchestrator-0" "Host"

vmFrame :: StepFrame
vmFrame = StepFrame "vm-orchestrator-1" "VM"

containerFrame :: StepFrame
containerFrame = StepFrame "vm-project-container-2" "Container"

withPlan :: (forall planId. LifecyclePlan FixtureScope planId -> IO ()) -> IO ()
withPlan use =
    withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
        withLifecyclePlan codec demoShapedPlan use

-- | A plan every one of whose steps preserves on reverse.
withPreservedPlan :: (forall planId. LifecyclePlan FixtureScope planId -> IO ()) -> IO ()
withPreservedPlan use =
    withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
        withLifecyclePlan codec allPreservedPlan use

planDigestOf :: LifecyclePlan FixtureScope planId -> Text
planDigestOf = lifecyclePlanDigest

openOrFail ::
    LifecyclePlan FixtureScope planId ->
    TeardownPlan FixtureScope planId verb ->
    IO (TeardownForest FixtureScope planId verb)
openOrFail plan projection =
    either (assertFailure . teardownErrorMessage) pure (openTeardownForest plan projection)

withDestroyForest ::
    (forall planId. TeardownForest FixtureScope planId DestroyVerb -> IO ()) -> IO ()
withDestroyForest use =
    withPlan $ \plan -> openOrFail plan (teardownPlan plan destroyVerb) >>= use

withDownForest ::
    (forall planId. TeardownForest FixtureScope planId DownVerb -> IO ()) -> IO ()
withDownForest use =
    withPlan $ \plan -> openOrFail plan (teardownPlan plan downVerb) >>= use

describeOpen :: Either TeardownError (TeardownForest scope planId verb) -> String
describeOpen = either teardownErrorMessage (const "an opened forest")

