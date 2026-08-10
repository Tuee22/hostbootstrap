{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The verb-indexed reverse projection and its teardown forest (the recursive-lifecycle-command phase).

The plan under test is the demo's own shape: a metal frame that ensures the
provider (preserve-on-reverse) and launches the VM, a VM frame that builds, and
a container frame that stands up the cluster and the chart. That shape is what
makes the child-first and pre-descent properties observable rather than
hypothetical.
-}
module TeardownSpec (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Fixture
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.HostConfig (HostConfig, buildHostConfig)
import HostBootstrap.Lift (localContext)
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    forward,
    plannedStepIdentity,
    plannedStepOperationKey,
    plannedStepReversePolicy,
    renderSnapshot,
    stablePlanSnapshotDigest,
 )
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import HostBootstrap.ProjectPlan.Frame (CurrentFrame, currentFrameId, withCurrentFrame)
import HostBootstrap.Step
import HostBootstrap.Substrate (detect)
import HostBootstrap.Teardown
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "TeardownSpec"
        [ testGroup "the reverse projection" projectionTests
        , testGroup "driving the projection" projectionDriverTests
        , testGroup "the forest" forestTests
        , testGroup "settlement" settlementTests
        , testGroup "the production driver" driverTests
        , testGroup "source shape" sourceShapeTests
        ]

{- | Pin the deliberate staging boundary between the plan projection and the
recursive forest. The reverse projection carries @frame@ only on
'TeardownPlan'; the recursive-lifecycle-command phase propagates it through the
successor types later. Keeping this as a source-shape check makes an accidental
early propagation, or a restored second opener argument, fail mechanically.
-}
sourceShapeTests :: [TestTree]
sourceShapeTests =
    [ testCase "only TeardownPlan is frame-indexed and the opener consumes it alone" $ do
        cwd <- getCurrentDirectory
        root <-
            findRepoRoot cwd
                >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        source <-
            TextIO.readFile
                ( root
                    </> "core"
                    </> "hostbootstrap-core"
                    </> "src"
                    </> "HostBootstrap"
                    </> "Teardown.hs"
                )
        let declarations = map Text.strip (Text.lines source)
            normalized = Text.unwords (Text.words source)
            declaration name expected =
                [ line
                | line <- declarations
                , ("data " <> name <> " ") `Text.isPrefixOf` line
                ]
                    @?= [expected]
            exactSignatures =
                [ "teardownPlan :: ProjectPlan scope specDigest planId configId cfg -> CurrentFrame scope planId frame -> TeardownVerb verb -> TeardownPlan scope planId frame verb"
                , "openTeardownForest :: TeardownPlan scope planId frame verb -> Either TeardownError (TeardownForest scope planId verb)"
                ]
        declaration
            "TeardownPlan"
            "data TeardownPlan scope planId frame verb"
        declaration
            "TeardownForest"
            "data TeardownForest scope planId verb"
        declaration
            "TeardownProgress"
            "data TeardownProgress scope planId verb"
        declaration
            "CompletedTeardownForest"
            "data CompletedTeardownForest scope planId verb"
        declaration
            "TeardownAuthorizationPoint"
            "data TeardownAuthorizationPoint scope planId verb"
        declaration
            "TeardownCursor"
            "data TeardownCursor scope planId verb = TeardownCursor ReverseStep"
        mapM_
            ( \signature ->
                assertBool
                    ("missing exact teardown signature: " ++ Text.unpack signature)
                    (signature `Text.isInfixOf` normalized)
            )
            exactSignatures
        assertBool
            "Teardown must consume only the public project-plan facade"
            (not ("import HostBootstrap.Lifecycle.Plan" `Text.isInfixOf` source))
        assertBool
            "Teardown must not retain the deleted LifecyclePlan compatibility projection"
            (not ("withCompatibilityTeardownPlan" `Text.isInfixOf` source))
    ]

{- | The loop a lifecycle verb runs (the recursive-lifecycle-command phase).

The verb supplies only one node's effect and one node's row; the ordering, the
retry policy, and the outstanding report are the forest's. These are the
properties the live verb depends on, taken here without a provider.
-}
driverTests :: [TestTree]
driverTests =
    [ testCase "the driver visits every node child-first and completes" $
        withPlan $ \plan current -> do
            visited <- newIORef []
            rows <- newIORef []
            let projection = teardownPlan plan current destroyVerb
            forest <- openOrFail projection
            driven <-
                driveTeardownForest
                    forest
                    ( \point -> do
                        modifyIORef' visited (++ [authorizationPointKey point])
                        pure TeardownReleased
                    )
                    (\key outcome -> modifyIORef' rows (++ [(key, outcome)]))
            case driven of
                Left outstanding -> assertFailure ("did not complete: " ++ show outstanding)
                Right completed ->
                    assertBool
                        "every projected identity settled"
                        ( all
                            (`elem` completedForestSettledKeys completed)
                            (teardownPlanStepKeys projection)
                        )
            -- the provider's pre-descent step first, then the deepest frame,
            -- then outwards; every node reports exactly one row
            readIORef visited
                >>= ( @?=
                        [ "core:deploy-vm"
                        , "core:deploy-chart"
                        , "core:deploy-kind"
                        , "core:build-pb"
                        , "core:deploy-vm"
                        ]
                    )
            observedRows <- readIORef rows
            map fst observedRows
                @?= [ "core:deploy-vm"
                    , "core:deploy-chart"
                    , "core:deploy-kind"
                    , "core:build-pb"
                    , "core:deploy-vm"
                    ]
            assertBool "every row is released" (all ((== TeardownReleased) . snd) observedRows)
    , testCase "a failed node stops the run and names every node left outstanding" $
        withPlan $ \plan current -> do
            attempts <- newIORef (0 :: Int)
            forest <- openOrFail (teardownPlan plan current destroyVerb)
            driven <-
                driveTeardownForest
                    forest
                    ( \point -> do
                        modifyIORef' attempts (+ 1)
                        pure $
                            if authorizationPointKey point == "core:deploy-chart"
                                then TeardownFailed "boom"
                                else TeardownReleased
                    )
                    (\_ _ -> pure ())
            case driven of
                Right _ -> assertFailure "a forest with a failing node must not complete"
                Left outstanding ->
                    assertBool
                        ("the blocked chain is named: " ++ show outstanding)
                        ( all
                            (`elem` outstanding)
                            ["core:deploy-chart", "core:build-pb", "core:deploy-vm"]
                        )
            -- the pre-descent step, the failing node, and its one schedulable
            -- sibling: the failing node is attempted once, not spun on
            readIORef attempts >>= (@?= 3)
    , testCase "a foreign or refused node settles and does not block completion" $
        withPlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current destroyVerb)
            driven <-
                driveTeardownForest
                    forest
                    ( \point ->
                        pure $
                            if authorizationPointKey point == "core:deploy-chart"
                                then TeardownForeignRetained "not this run's release"
                                else TeardownReleased
                    )
                    (\_ _ -> pure ())
            case driven of
                Left outstanding -> assertFailure ("did not complete: " ++ show outstanding)
                Right _ -> pure ()
    , testCase "only a destroy run can mint settled-destroy evidence" $
        withPlan $ \plan current -> do
            let destroyProjection = teardownPlan plan current destroyVerb
                downProjection = teardownPlan plan current downVerb
            destroyForest <- openOrFail destroyProjection
            downForest <- openOrFail downProjection
            destroyDone <- driveTeardownForest destroyForest (const (pure TeardownReleased)) (\_ _ -> pure ())
            downDone <- driveTeardownForest downForest (const (pure TeardownReleased)) (\_ _ -> pure ())
            case (destroyDone, downDone) of
                (Right destroyed, Right downed) -> do
                    case settledDestroyEvidence downProjection downed of
                        Nothing -> pure ()
                        Just _ -> assertFailure "a down run minted settled-destroy evidence"
                    case settledDestroyEvidence destroyProjection destroyed of
                        Just (Right settled) ->
                            destroySettledPlanDigest settled @?= planDigestOf plan
                        other ->
                            assertFailure
                                ("expected settled-destroy evidence, got " ++ describeEvidence other)
                _ -> assertFailure "both forests must complete"
    ]

describeEvidence :: Maybe (Either TeardownError a) -> String
describeEvidence Nothing = "no evidence (a down projection)"
describeEvidence (Just (Left err)) = teardownErrorMessage err
describeEvidence (Just (Right _)) = "settled"

-- ---------------------------------------------------------------------------
-- Projection

projectionTests :: [TestTree]
projectionTests =
    [ testCase "forward and reverse share exact identities and operation keys" $
        withPlan $ \plan current -> do
            let forwardReverseNodes =
                    reverse
                        [ node
                        | node <- NonEmpty.toList (forward plan)
                        , plannedStepReversePolicy node /= PreserveOnReverse
                        ]
                expectedIdentities = map plannedStepIdentity forwardReverseNodes
                expectedOperations = map plannedStepOperationKey forwardReverseNodes
                down = teardownPlan plan current downVerb
                destroy = teardownPlan plan current destroyVerb
            teardownPlanStepIdentities down @?= expectedIdentities
            teardownPlanStepIdentities destroy @?= expectedIdentities
            teardownPlanOperationKeys down @?= expectedOperations
            teardownPlanOperationKeys destroy @?= expectedOperations
            teardownPlanStepKeys down @?= map (Text.pack . ProjectPlan.operationKeyText) expectedOperations
            teardownPlanStepKeys destroy
                @?= [ "core:deploy-chart"
                    , "core:deploy-kind"
                    , "core:build-pb"
                    , "core:deploy-vm"
                    ]
    , testCase "root, VM, and container projections retain their exact suffix" $ do
        assertPlanSuffix
            id
            "host-orchestrator-0"
            ["core:deploy-chart", "core:deploy-kind", "core:build-pb", "core:deploy-vm"]
        assertPlanSuffix
            (\root -> Context.deriveVMContext root "/fixture/vm")
            "vm-orchestrator-1"
            ["core:deploy-chart", "core:deploy-kind", "core:build-pb"]
        assertPlanSuffix
            ( \root ->
                Context.deriveContainerContext
                    (Context.deriveVMContext root "/fixture/vm")
                    "/fixture/container"
            )
            "vm-project-container-2"
            ["core:deploy-chart", "core:deploy-kind"]
    , testCase "a preserve-on-reverse step is in neither projection" $
        withPlan $ \plan current ->
            assertBool
                "the preserved provider-ensure step is absent"
                ( "project:ensure-vm-provider"
                    `notElem` teardownPlanStepKeys (teardownPlan plan current destroyVerb)
                )
    , testCase "the provider is stopped by down and deleted by destroy" $
        withPlan $ \plan current -> do
            lookup "core:deploy-vm" (teardownPlanActions (teardownPlan plan current downVerb))
                @?= Just StopFrame
            lookup "core:deploy-vm" (teardownPlanActions (teardownPlan plan current destroyVerb))
                @?= Just DeleteFrame
    , testCase "the kind cluster is deleted by both verbs, because kind has no stop" $
        withPlan $ \plan current -> do
            lookup "core:deploy-kind" (teardownPlanActions (teardownPlan plan current downVerb))
                @?= Just DeleteCluster
            lookup "core:deploy-kind" (teardownPlanActions (teardownPlan plan current destroyVerb))
                @?= Just DeleteCluster
    , testCase "a plan whose every step preserves projects nothing and cannot open" $
        withPreservedPlan $ \plan current ->
            case openTeardownForest (teardownPlan plan current destroyVerb) of
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
    [ testCase "projection and forest construction retain callbacks without running them" $
        withReversedPlan $ \plan current observed -> do
            let projection = teardownPlan plan current destroyVerb
            readIORef observed >>= (@?= [])
            _ <- openOrFail projection
            readIORef observed >>= (@?= [])
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
        withReversedPlan $ \plan current observed -> do
            _ <- runTeardownProjection (teardownPlan plan current downVerb) neverCore hostConfigFixture
            seen <- readIORef observed
            lookup "core:deploy-vm" seen @?= Just StopFrame
    , testCase "a node that declared no reverse is skipped, not silently released" $
        withReversedPlan $ \plan current _ -> do
            outcomes <- runTeardownProjection (teardownPlan plan current destroyVerb) neverCore hostConfigFixture
            lookup "core:deploy-kind" outcomes @?= Just (Just coreHandled)
            -- `copy-source` declares neither a reverse nor core management.
            lookup "core:copy-source" outcomes @?= Just Nothing
    , -- The core adapter must be able to tell the cluster apart from the
      -- core-managed resources that live *inside* it, or it would run the
      -- cluster teardown once per node. The action is what carries that.
      testCase "the core adapter receives each node's own action" $
        withReversedPlan $ \plan current _ -> do
            seen <- newIORef []
            let recordCore key coreAction = do
                    modifyIORef' seen (++ [(key, coreAction)])
                    pure TeardownReleased
            _ <- runTeardownProjection (teardownPlan plan current destroyVerb) recordCore hostConfigFixture
            readIORef seen >>= (@?= [("core:deploy-kind", DeleteCluster)])
    , testCase "a throwing reverse becomes a failure and later nodes still run" $
        withThrowingPlan $ \plan current reached -> do
            outcomes <- runTeardownProjection (teardownPlan plan current destroyVerb) neverCore hostConfigFixture
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
        withPlan $ \plan current -> do
            let projection = teardownPlan plan current destroyVerb
            forest <- openOrFail projection
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
        withPlan $ \plan current -> do
            let projection = teardownPlan plan current destroyVerb
            forest <- openOrFail projection
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
    ( forall projectId specDigest planId configId frame.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      CurrentFrame (Production projectId) planId frame ->
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
    withExactPlan id plan (\projectPlan current -> consume projectPlan current observed)

-- | A plan whose @build-pb@ reverse throws, with a later node that must still run.
withThrowingPlan ::
    ( forall projectId specDigest planId configId frame.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      CurrentFrame (Production projectId) planId frame ->
      IORef Bool ->
      IO result
    ) ->
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
    withExactPlan id plan (\projectPlan current -> consume projectPlan current reached)

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

withExactPlan ::
    (Context.BinaryContext -> Context.BinaryContext) ->
    StepPlan ->
    ( forall projectId specDigest planId configId frame.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      CurrentFrame (Production projectId) planId frame ->
      IO result
    ) ->
    IO result
withExactPlan selectContext stepPlan use =
    Fixture.withFixtureProjectPlanContext selectContext stepPlan $ \plan exactContext ->
        case withCurrentFrame plan exactContext (\current _projectFrame _validated -> use plan current) of
            Left failure -> assertFailure (show failure)
            Right action -> action

withPlan ::
    ( forall projectId specDigest planId configId frame.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      CurrentFrame (Production projectId) planId frame ->
      IO ()
    ) ->
    IO ()
withPlan = withExactPlan id demoShapedPlan

-- | A plan every one of whose steps preserves on reverse.
withPreservedPlan ::
    ( forall projectId specDigest planId configId frame.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      CurrentFrame (Production projectId) planId frame ->
      IO ()
    ) ->
    IO ()
withPreservedPlan = withExactPlan id allPreservedPlan

planDigestOf :: ProjectPlan scope specDigest planId configId cfg -> Text
planDigestOf = stablePlanSnapshotDigest . renderSnapshot

openOrFail ::
    TeardownPlan scope planId frame verb ->
    IO (TeardownForest scope planId verb)
openOrFail projection =
    either (assertFailure . teardownErrorMessage) pure (openTeardownForest projection)

withDestroyForest ::
    ( forall projectId planId.
      TeardownForest (Production projectId) planId DestroyVerb ->
      IO ()
    ) ->
    IO ()
withDestroyForest use =
    withPlan $ \plan current -> openOrFail (teardownPlan plan current destroyVerb) >>= use

withDownForest ::
    ( forall projectId planId.
      TeardownForest (Production projectId) planId DownVerb ->
      IO ()
    ) ->
    IO ()
withDownForest use =
    withPlan $ \plan current -> openOrFail (teardownPlan plan current downVerb) >>= use

assertPlanSuffix ::
    (Context.BinaryContext -> Context.BinaryContext) ->
    Text ->
    [Text] ->
    IO ()
assertPlanSuffix selectContext expectedFrame expectedKeys =
    withExactPlan selectContext demoShapedPlan $ \plan current -> do
        let projection = teardownPlan plan current destroyVerb
        currentFrameId current @?= expectedFrame
        teardownPlanFrameId projection @?= expectedFrame
        teardownPlanStepKeys projection @?= expectedKeys

describeOpen :: Either TeardownError (TeardownForest scope planId verb) -> String
describeOpen = either teardownErrorMessage (const "an opened forest")
