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

import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Fixture
import HostBootstrap.Authority (
    ProjectVerb (..),
    VerbDestroy,
    VerbDown,
    projectVerbName,
 )
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Handoff (frameWire, renderLifecycleObservations)
import HostBootstrap.HostConfig (HostConfig, buildHostConfig)
import HostBootstrap.Lift (localContext)
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    forward,
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
import Unsafe.Coerce (unsafeCoerce)

tests :: TestTree
tests =
    testGroup
        "TeardownSpec"
        [ testGroup "the reverse projection" projectionTests
        , testGroup "the forest" forestTests
        , testGroup "the observation codec" observationCodecTests
        , testGroup "settlement" settlementTests
        , testGroup "the production driver" driverTests
        , testGroup "source shape" sourceShapeTests
        ]

observationCodecTests :: [TestTree]
observationCodecTests =
    [ testCase "all four teardown outcomes round-trip in exact order on the shared wire" $ do
        let observations =
                [ ("release", TeardownReleased)
                , ("foreign", TeardownForeignRetained "owned elsewhere")
                , ("refusal", TeardownRefused "policy")
                , ("failure", TeardownFailed "provider")
                ]
            structuralRows =
                [ ("release", "released", "none")
                , ("foreign", "foreign-retained", "owned elsewhere")
                , ("refusal", "refused", "policy")
                , ("failure", "failed", "provider")
                ]
        wire <- expectTeardownRight (renderTeardownObservations observations)
        structural <- expectHandoffRight (renderLifecycleObservations structuralRows)
        wire @?= structural
        teardownObservationsFromWire wire @?= Right observations
    , testCase "typed rendering preserves lower key and detail refusals" $ do
        let malformed =
                [ ("empty key", [("", TeardownReleased)])
                , ("duplicate key", [("same", TeardownReleased), ("same", TeardownReleased)])
                , ("empty foreign detail", [("one", TeardownForeignRetained "")])
                , ("none foreign detail", [("one", TeardownForeignRetained "none")])
                , ("empty refusal detail", [("one", TeardownRefused "")])
                , ("none refusal detail", [("one", TeardownRefused "none")])
                , ("empty failure detail", [("one", TeardownFailed "")])
                , ("none failure detail", [("one", TeardownFailed "none")])
                ]
        forM_ malformed $ \(label, observations) ->
            case renderTeardownObservations observations of
                Left (TeardownObservationWireRefused _) -> pure ()
                other -> assertFailure (label <> " was not refused: " <> show other)
    , testCase "typed decoding refuses malformed, truncated, and trailing structural wires" $ do
        wire <- expectTeardownRight (renderTeardownObservations [("one", TeardownReleased)])
        let malformed =
                [ ("truncated", ByteString.init wire)
                , ("trailing", wire <> frameWire "extra")
                , ("malformed UTF-8", malformedTeardownObservationWire)
                ]
        forM_ malformed $ \(label, candidate) ->
            case teardownObservationsFromWire candidate of
                Left (TeardownObservationWireRefused _) -> pure ()
                other -> assertFailure (label <> " wire was not refused: " <> show other)
    ]

expectTeardownRight :: (Show error) => Either error value -> IO value
expectTeardownRight (Right value) = pure value
expectTeardownRight (Left failure) = assertFailure ("expected teardown codec success: " <> show failure)

expectHandoffRight :: (Show error) => Either error value -> IO value
expectHandoffRight (Right value) = pure value
expectHandoffRight (Left failure) = assertFailure ("expected structural codec success: " <> show failure)

malformedTeardownObservationWire :: ByteString.ByteString
malformedTeardownObservationWire =
    ByteString.concat
        [ frameWire "hostbootstrap/lifecycle-observations"
        , frameWire (ByteString.replicate 7 0 <> ByteString.singleton 1)
        , frameWire (ByteString.replicate 7 0 <> ByteString.singleton 1)
        , frameWire (ByteString.pack [0xff])
        , frameWire "released"
        , frameWire "none"
        ]

{- | Pin the exact frame lineage from the projection through every recursive
forest package. Keeping this as a source-shape check makes a dropped frame
index, a representationally coercible phantom, or a restored second opener
argument fail mechanically.
-}
sourceShapeTests :: [TestTree]
sourceShapeTests =
    [ testCase "the complete forest pipeline retains the projection frame" $ do
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
        commandSource <-
            TextIO.readFile
                ( root
                    </> "core"
                    </> "hostbootstrap-core"
                    </> "src"
                    </> "HostBootstrap"
                    </> "Command.hs"
                )
        internalSource <-
            TextIO.readFile
                ( root
                    </> "core"
                    </> "hostbootstrap-core"
                    </> "src"
                    </> "HostBootstrap"
                    </> "Teardown"
                    </> "Internal.hs"
                )
        let declarations = map Text.strip (Text.lines source)
            normalized = Text.unwords (Text.words source)
            declaration name expected =
                [ line
                | line <- declarations
                , any
                    (`Text.isPrefixOf` line)
                    ["data " <> name <> " ", "newtype " <> name <> " "]
                ]
                    @?= [expected]
            exactSignatures =
                [ "teardownPlan :: ProjectPlan scope specDigest planId configId cfg -> CurrentFrame scope planId frame -> ProjectVerb verb -> TeardownPlan scope planId frame verb"
                , "openTeardownForest :: TeardownPlan scope planId frame verb -> Either TeardownError (TeardownForest scope planId frame verb)"
                , "nextTeardownWork :: TeardownForest scope planId frame verb -> TeardownProgress scope planId frame verb"
                , "eliminateTeardownWork :: TeardownWork scope planId frame verb -> (LocalWork scope planId frame verb -> result) -> (forall (childFrame :: Type). DescentWork scope planId frame childFrame verb -> result) -> result"
                , "attemptLocalWork :: LocalWork scope planId frame verb -> TeardownOutcome -> TeardownForest scope planId frame verb"
                , "withDescentWorkSubtree :: DescentWork scope planId frame childFrame verb -> (TeardownPlan scope planId childFrame verb -> result) -> result"
                , "settleDescentWork :: DescentWork scope planId frame childFrame verb -> SubtreeSettled scope planId childFrame verb -> Either TeardownError (TeardownForest scope planId frame verb)"
                , "driveTeardownForest :: TeardownForest scope planId frame verb -> (PreDescentStep scope planId frame verb -> IO TeardownOutcome) -> (SettledChildren scope planId frame -> LocalWork scope planId frame verb -> IO TeardownOutcome) -> ( forall (childFrame :: Type). SettledChildren scope planId frame -> DescentWork scope planId frame childFrame verb -> IO (Either Text (SubtreeSettled scope planId childFrame verb)) ) -> (Text -> TeardownOutcome -> IO ()) -> IO (Either [Text] (CompletedTeardownForest scope planId frame verb))"
                , "verifySubtreeSettled :: TeardownPlan scope planId frame verb -> CompletedTeardownForest scope planId frame verb -> Either TeardownError (SubtreeSettled scope planId frame verb)"
                , "verifyDestroySettled :: ProjectPlan scope specDigest planId configId cfg -> CurrentFrame scope planId frame -> SubtreeSettled scope planId frame VerbDestroy -> Either TeardownError (DestroySettled scope planId)"
                ]
            exactRoles =
                [ "type role TeardownPlan nominal nominal nominal nominal"
                , "type role TeardownForest nominal nominal nominal nominal"
                , "type role TeardownProgress nominal nominal nominal nominal"
                , "type role CompletedTeardownForest nominal nominal nominal nominal"
                , "type role TeardownAuthorizationPoint nominal nominal nominal nominal"
                , "type role PreDescentStep nominal nominal nominal nominal"
                , "type role SettledChildren nominal nominal nominal"
                , "type role TeardownWork nominal nominal nominal nominal"
                , "type role LocalWork nominal nominal nominal nominal"
                , "type role DescentWork nominal nominal nominal nominal nominal"
                , "type role SubtreeSettled nominal nominal nominal nominal"
                , "type role DestroySettled nominal nominal"
                ]
        declaration
            "TeardownPlan"
            "data TeardownPlan scope planId frame verb"
        declaration
            "TeardownForest"
            "data TeardownForest scope planId frame verb"
        declaration
            "TeardownProgress"
            "data TeardownProgress scope planId frame verb"
        declaration
            "CompletedTeardownForest"
            "data CompletedTeardownForest scope planId frame verb"
        declaration
            "TeardownAuthorizationPoint"
            "data TeardownAuthorizationPoint scope planId frame verb"
        declaration
            "PreDescentStep"
            "newtype PreDescentStep scope planId frame verb"
        declaration
            "SettledChildren"
            "newtype SettledChildren scope planId frame = SettledChildren [Text]"
        declaration
            "TeardownWork"
            "data TeardownWork scope planId frame verb where"
        declaration
            "LocalWork"
            "data LocalWork scope planId frame verb"
        declaration
            "DescentWork"
            "data DescentWork scope planId frame (childFrame :: Type) verb"
        declaration
            "SubtreeSettled"
            "data SubtreeSettled scope planId frame verb"
        declaration
            "DestroySettled"
            "data DestroySettled scope planId"
        mapM_
            ( \signature ->
                assertBool
                    ("missing exact teardown signature: " ++ Text.unpack signature)
                    (signature `Text.isInfixOf` normalized)
            )
            exactSignatures
        mapM_
            ( \role ->
                assertBool
                    ("missing exact teardown role declaration: " ++ Text.unpack role)
                    (role `Text.isInfixOf` normalized)
            )
            exactRoles
        assertBool
            "the former TeardownCursor type must not remain public"
            (not ("    TeardownCursor," `Text.isInfixOf` source))
        mapM_
            ( \formerProjection ->
                assertBool
                    ("former public cursor projection remains: " ++ Text.unpack formerProjection)
                    (not (formerProjection `Text.isInfixOf` source))
            )
            [ "teardownCursorAction"
            , "teardownCursorKey"
            , "teardownCursorFrame"
            , "teardownCursorPolicy"
            , "teardownCursorRun"
            , "attemptTeardownStep"
            , "teardownPlanStepKeys"
            , "teardownPlanStepIdentities"
            , "teardownPlanOperationKeys"
            , "teardownPlanActions"
            , "runTeardownProjection"
            , "attemptDescentWork"
            ]
        mapM_
            ( \required ->
                assertBool
                    ("Command is missing the closed teardown-work boundary: " ++ Text.unpack required)
                    (required `Text.isInfixOf` commandSource)
            )
            [ "Teardown.LocalWork"
            , "Teardown.DescentWork"
            , "Teardown.driveTeardownForest"
            , "Teardown.withDescentWorkSubtree"
            , "Teardown.descentWorkParentFrame"
            , "Teardown.descentWorkChildFrame"
            , "nextFrameAfter (topology plan) parent"
            , "plan-bound teardown descent mismatch"
            ]
        assertBool
            "Command must not retain the former public cursor route"
            (not ("Teardown.TeardownCursor" `Text.isInfixOf` commandSource))
        assertBool
            "Command must not receive an unclassified teardown authorization point"
            (not ("Teardown.withTeardownAuthorization" `Text.isInfixOf` commandSource))
        assertBool
            "the driver must not expose the former generic authorization-point handler"
            ( not
                ( "(TeardownAuthorizationPoint scope planId frame verb -> IO TeardownOutcome)"
                    `Text.isInfixOf` normalized
                )
            )
        assertBool
            "Teardown must consume only the public project-plan facade"
            (not ("import HostBootstrap.Lifecycle.Plan" `Text.isInfixOf` source))
        assertBool
            "Teardown must not retain the deleted LifecyclePlan compatibility projection"
            (not ("withCompatibilityTeardownPlan" `Text.isInfixOf` source))
        mapM_
            ( \legacyVerb ->
                assertBool
                    ("legacy teardown verb remains: " ++ Text.unpack legacyVerb)
                    (not (legacyVerb `Text.isInfixOf` source))
            )
            [ "DownVerb"
            , "DestroyVerb"
            , "TeardownVerb"
            , "downVerb"
            , "destroyVerb"
            , "teardownVerbName"
            ]
        mapM_
            ( \required ->
                assertBool
                    ("missing canonical ProjectVerb behavior: " ++ Text.unpack required)
                    (required `Text.isInfixOf` normalized)
            )
            [ "= TeardownPlan (ProjectVerb verb) Bool Text Text [Text] [[ReverseStep]]"
            , "= TeardownForest (TeardownPlan scope planId frame verb) [Node]"
            , "= CompletedTeardownForest (ProjectVerb verb) Text Text [(OperationKey, TeardownOutcome)]"
            , "actionFor ProjectUp _ = Nothing"
            , "actionFor ProjectDown (CoreStepIdentity DeployVMId) = Just StopFrame"
            , "actionFor ProjectDestroy (CoreStepIdentity DeployVMId) = Just DeleteFrame"
            , "openTeardownForest projection@(TeardownPlan verb failedUp _ _ _ levels) | ProjectUp <- verb, not failedUp = Left TeardownProjectUpHasNoReverse"
            , "ProjectUp -> Nothing ProjectDown -> Nothing ProjectDestroy -> Just (verifyDestroySettled plan current settled)"
            ]
        assertBool
            "Command must carry one canonical verb through recursive argv"
            ("Authority.projectVerbName verb" `Text.isInfixOf` commandSource)
        assertBool
            "Command must select cluster teardown only from the canonical verb"
            ( "clusterEffectFor selected = case selected of Authority.ProjectUp -> False Authority.ProjectDown -> True Authority.ProjectDestroy -> True"
                `Text.isInfixOf` Text.unwords (Text.words commandSource)
            )
        assertBool
            "Command must not retain parallel command/teardown verb parameters"
            ( not ("commandVerb" `Text.isInfixOf` commandSource)
                && not ("teardownVerb" `Text.isInfixOf` commandSource)
            )
        assertBool
            "Command must not accept an external cluster teardown callback"
            (not ("(ClusterPlan -> IO TeardownOutcome)" `Text.isInfixOf` commandSource))
        assertBool
            "the exact Harness destroy route must use retained cluster ownership internally"
            ( "releaseRetainedClusterLifecycle cfg (planForRootWithProfile profile root ctx)"
                `Text.isInfixOf` commandSource
            )
        assertBool
            "the exact Harness destroy route must derive that profile from its admitted plan"
            ( "profileFromPlanName (ProjectPlan.projectPlanProfileName destroyPlan)"
                `Text.isInfixOf` commandSource
            )
        assertBool
            "the recursive child adapter must derive cluster cleanup from its admitted plan profile"
            ( "profileFromPlanName (ProjectPlan.projectPlanProfileName plan)"
                `Text.isInfixOf` commandSource
                && "planForRootWithProfile profile root ctx" `Text.isInfixOf` commandSource
            )
        assertBool
            "Harness recovery offers compare the canonical signed scope, not the lifecycle journal spelling"
            ( "Text.stripPrefix \"harness:\" stableScope" `Text.isInfixOf` internalSource
                && "\"Harness \" <> run" `Text.isInfixOf` internalSource
                && "handoffScope binding == recoveryHandoffScope" `Text.isInfixOf` internalSource
            )
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
            let projection = teardownPlan plan current ProjectDestroy
            forest <- openOrFail projection
            let expectedKeys = teardownForestOutstanding forest
            driven <-
                driveWithOffered
                    forest
                    ( \work -> do
                        modifyIORef' visited (++ [work])
                        pure TeardownReleased
                    )
                    (\key outcome -> modifyIORef' rows (++ [(key, outcome)]))
            case driven of
                Left outstanding -> assertFailure ("did not complete: " ++ show outstanding)
                Right completed ->
                    assertBool
                        "every projected identity settled"
                        ( all
                            (`elem` terminalKeyTexts (completedForestTerminalObservations completed))
                            expectedKeys
                        )
            -- the provider's pre-descent step first, then the deepest frame,
            -- then outwards; every node reports exactly one row
            readIORef visited
                >>= ( @?=
                        [ OfferedPreDescent "core:deploy-vm" "host-orchestrator-0"
                        , OfferedDescent "host-orchestrator-0" "vm-orchestrator-1"
                        , OfferedDescent "vm-orchestrator-1" "vm-project-container-2"
                        , OfferedLocal "core:deploy-chart" ReleaseResource
                        , OfferedLocal "core:deploy-kind" DeleteCluster
                        , OfferedLocal "core:build-pb" ReleaseResource
                        , OfferedLocal "core:deploy-vm" DeleteFrame
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
            failedFirstDescent <- newIORef False
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            driven <-
                driveWithOffered
                    forest
                    ( \work -> do
                        modifyIORef' attempts (+ 1)
                        case work of
                            OfferedDescent _ _ -> do
                                alreadyFailed <- readIORef failedFirstDescent
                                if alreadyFailed
                                    then pure TeardownReleased
                                    else do
                                        writeIORef failedFirstDescent True
                                        pure (TeardownFailed "boom")
                            _ -> pure TeardownReleased
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
            -- The pre-descent step and one failed child-subtree attempt. The
            -- exact child continuation fails as a unit, so no sibling can
            -- bypass it and no raw-success retry spins in this run.
            readIORef attempts >>= (@?= 2)
    , testCase "foreign and refused child observations remain distinct and do not block completion" $
        withPlan $ \plan current -> do
            retainedChart <- newIORef False
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            driven <-
                driveWithOffered
                    forest
                    ( \work -> case work of
                        OfferedLocal "core:deploy-chart" _ -> do
                            alreadyRetained <- readIORef retainedChart
                            if alreadyRetained
                                then pure (TeardownRefused "policy retained the chart")
                                else do
                                    writeIORef retainedChart True
                                    pure (TeardownForeignRetained "not this run's release")
                        OfferedLocal "core:deploy-kind" _ ->
                            pure (TeardownRefused "policy retained the cluster")
                        _ -> pure TeardownReleased
                    )
                    (\_ _ -> pure ())
            case driven of
                Left outstanding -> assertFailure ("did not complete: " ++ show outstanding)
                Right completed -> do
                    subtree <-
                        either
                            (assertFailure . teardownErrorMessage)
                            pure
                            (verifySubtreeSettled (teardownPlan plan current ProjectDestroy) completed)
                    map snd (subtreeSettledTerminalObservations subtree)
                        @?= [ TeardownForeignRetained "not this run's release"
                            , TeardownRefused "policy retained the cluster"
                            , TeardownReleased
                            , TeardownReleased
                            ]
    , testCase "only a destroy run can mint settled-destroy evidence" $
        withPlan $ \plan current -> do
            let destroyProjection = teardownPlan plan current ProjectDestroy
                downProjection = teardownPlan plan current ProjectDown
            destroyForest <- openOrFail destroyProjection
            downForest <- openOrFail downProjection
            destroyDone <- driveWithOffered destroyForest (const (pure TeardownReleased)) (\_ _ -> pure ())
            downDone <- driveWithOffered downForest (const (pure TeardownReleased)) (\_ _ -> pure ())
            case (destroyDone, downDone) of
                (Right destroyed, Right downed) -> do
                    downSubtree <-
                        either
                            (assertFailure . teardownErrorMessage)
                            pure
                            (verifySubtreeSettled downProjection downed)
                    destroySubtree <-
                        either
                            (assertFailure . teardownErrorMessage)
                            pure
                            (verifySubtreeSettled destroyProjection destroyed)
                    case settledDestroyEvidence plan current downSubtree of
                        Nothing -> pure ()
                        Just _ -> assertFailure "a down run minted settled-destroy evidence"
                    case settledDestroyEvidence plan current destroySubtree of
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
    [ testCase "the projection retains the exact canonical project verb" $
        withPlan $ \plan current -> do
            teardownPlanVerbName (teardownPlan plan current ProjectUp)
                @?= projectVerbName ProjectUp
            teardownPlanVerbName (teardownPlan plan current ProjectDown)
                @?= projectVerbName ProjectDown
            teardownPlanVerbName (teardownPlan plan current ProjectDestroy)
                @?= projectVerbName ProjectDestroy
    , testCase "the forest report uses only the plan's exact operation keys" $
        withPlan $ \plan current -> do
            let forwardReverseNodes =
                    reverse
                        [ node
                        | node <- NonEmpty.toList (forward plan)
                        , plannedStepReversePolicy node /= PreserveOnReverse
                        ]
                expectedKeys =
                    map
                        (Text.pack . ProjectPlan.operationKeyText . plannedStepOperationKey)
                        forwardReverseNodes
            downForest <- openOrFail (teardownPlan plan current ProjectDown)
            destroyForest <- openOrFail (teardownPlan plan current ProjectDestroy)
            teardownForestOutstanding downForest @?= expectedKeys
            teardownForestOutstanding destroyForest @?= expectedKeys
    , testCase "root, VM, and container projections open exact frame-bound suffixes" $ do
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
    , testCase "same-frame bootstrap work cannot precede its child subtree" $
        withExactPlan id workedDemoReversePlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            teardownForestOutstanding forest
                @?= [ "core:deploy-chart"
                    , "core:deploy-kind"
                    , "core:context-init"
                    , "core:copy-source"
                    , "core:build-pb"
                    , "core:deploy-vm"
                    ]
    , testCase "a preserve-on-reverse step is in neither projection" $
        withPlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            assertBool
                "the preserved provider-ensure step is absent"
                ( "project:ensure-vm-provider"
                    `notElem` teardownForestOutstanding forest
                )
    , testCase "the provider is stopped by down and deleted by destroy" $
        withPlan $ \plan current -> do
            downForest <- openOrFail (teardownPlan plan current ProjectDown)
            destroyForest <- openOrFail (teardownPlan plan current ProjectDestroy)
            localActionFor "core:deploy-vm" downForest @?= Just StopFrame
            localActionFor "core:deploy-vm" destroyForest @?= Just DeleteFrame
    , testCase "the kind cluster is deleted by both verbs, because kind has no stop" $
        withExactPlan inContainer demoShapedPlan $ \plan current -> do
            downForest <- openOrFail (teardownPlan plan current ProjectDown)
            destroyForest <- openOrFail (teardownPlan plan current ProjectDestroy)
            localActionFor "core:deploy-kind" downForest @?= Just DeleteCluster
            localActionFor "core:deploy-kind" destroyForest @?= Just DeleteCluster
    , testCase "project up refuses before exposing reverse work from a removable plan" $
        withPlan $ \plan current -> do
            let projection = teardownPlan plan current ProjectUp
            teardownPlanVerbName projection @?= projectVerbName ProjectUp
            case openTeardownForest projection of
                Left TeardownProjectUpHasNoReverse -> pure ()
                other -> assertFailure ("expected the project-up refusal, got " ++ describeOpen other)
    , testCase "project up refusal takes precedence over the empty-plan error" $
        withPreservedPlan $ \plan current ->
            case openTeardownForest (teardownPlan plan current ProjectUp) of
                Left TeardownProjectUpHasNoReverse -> pure ()
                other -> assertFailure ("expected the project-up refusal, got " ++ describeOpen other)
    , testCase "failed-Up cleanup retains Up while projecting only the exact reached prefix" $
        withPlan $ \plan current -> do
            projected <-
                either
                    (assertFailure . teardownErrorMessage)
                    pure
                    (failedUpTeardownPlanKernel plan current ["core:deploy-vm", "core:build-pb"])
            teardownPlanVerbName projected @?= projectVerbName ProjectUp
            forest <- openOrFail projected
            teardownForestOutstanding forest @?= ["core:build-pb", "core:deploy-vm"]
            localActionFor "core:deploy-vm" forest @?= Just DeleteFrame
            case failedUpTeardownPlanKernel plan current ["core:deploy-vm", "core:deploy-vm"] of
                Left (TeardownReverseDescentRefused _) -> pure ()
                other -> assertFailure ("duplicate reached operations were accepted: " ++ showProjection other)
            case failedUpTeardownPlanKernel plan current ["project:not-in-plan"] of
                Left (TeardownReverseDescentRefused _) -> pure ()
                other -> assertFailure ("a foreign reached operation was accepted: " ++ showProjection other)
    , testCase "failed-Up cleanup filters reached preserved nodes and projected relations" $
        withExactPlan id failedUpObservedPlan $ \plan current -> do
            projected <-
                either (assertFailure . teardownErrorMessage) pure $
                    failedUpTeardownPlanKernel
                        plan
                        current
                        [ "project:ensure-vm-provider"
                        , "project:ensure-vm-provider/guest-alias"
                        , "core:deploy-vm"
                        ]
            forest <- openOrFail projected
            teardownForestOutstanding forest @?= ["core:deploy-vm"]
    , testCase "a plan whose every step preserves projects nothing and cannot open" $
        withPreservedPlan $ \plan current ->
            case openTeardownForest (teardownPlan plan current ProjectDestroy) of
                Left (TeardownPlanEmpty "destroy") -> pure ()
                other -> assertFailure ("expected an empty projection, got " ++ describeOpen other)
    ]
  where
    showProjection = either teardownErrorMessage (const "projection")
    inContainer root =
        Context.deriveContainerContext
            (Context.deriveVMContext root "/fixture/vm")
            "/fixture/container"

-- ---------------------------------------------------------------------------
-- The forest

forestTests :: [TestTree]
forestTests =
    [ testCase "destroy offers the provider's pre-descent step before any child" $
        withDestroyForest $ \forest ->
            firstWork forest
                @?= Just (OfferedPreDescent "core:deploy-vm" "host-orchestrator-0")
    , testCase "down never offers a pre-descent step" $
        withDownForest $ \forest ->
            -- The deepest frame's own step is first, because a down does not
            -- descend past a stopped provider.
            firstWork forest
                @?= Just (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
    , testCase "the pre-descent step exposes the children, not the provider itself" $
        withDestroyForest $ \forest -> do
            let afterReach = attempt forest TeardownReleased
            firstWork afterReach
                @?= Just (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
    , testCase "root, VM, and container openings classify only their immediate edge" $ do
        assertFirstOrdinaryPlacement
            id
            demoShapedPlan
            (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
        assertFirstOrdinaryPlacement
            (\root -> Context.deriveVMContext root "/fixture/vm")
            demoShapedPlan
            (OfferedDescent "vm-orchestrator-1" "vm-project-container-2")
        assertFirstOrdinaryPlacement
            ( \root ->
                Context.deriveContainerContext
                    (Context.deriveVMContext root "/fixture/vm")
                    "/fixture/container"
            )
            demoShapedPlan
            (OfferedLocal "core:deploy-chart" ReleaseResource)
    , testCase "an empty removable intermediate level still binds the immediate edge" $
        assertFirstOrdinaryPlacement
            id
            emptyIntermediateReversePlan
            (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
    , testCase "only local work projects and runs a declared reverse" $ do
        observed <- newIORef []
        let plan = executableContainerPlan observed
            containerContext root =
                Context.deriveContainerContext
                    (Context.deriveVMContext root "/fixture/vm")
                    "/fixture/container"
        withExactPlan containerContext plan $ \exactPlan current -> do
            forest <- openOrFail (teardownPlan exactPlan current ProjectDestroy)
            eliminateTeardownProgress
                (nextTeardownWork forest)
                (\_ -> assertFailure "the local forest completed before its declared reverse")
                ( \point ->
                    withTeardownAuthorization
                        point
                        (\_ -> assertFailure "container-local work became pre-descent")
                        ( \_ work ->
                            eliminateTeardownWork
                                work
                                ( \local -> do
                                    localWorkKey local @?= "core:deploy-chart"
                                    localWorkAction local @?= ReleaseResource
                                    case localWorkRun local of
                                        Nothing -> assertFailure "the declared local reverse was lost"
                                        Just run -> do
                                            outcome <- run hostConfigFixture (localWorkAction local)
                                            outcome @?= TeardownReleased
                                    readIORef observed
                                        >>= (@?= [("core:deploy-chart", ReleaseResource)])
                                    teardownForestOutstanding
                                        (attemptLocalWork local TeardownReleased)
                                        @?= []
                                )
                                (\_ -> assertFailure "container-local work became descent")
                        )
                )
    , testCase "a parent is not offered until its exact child set settles" $
        withDestroyForest $ \forest -> do
            let order = drainOrder forest
            order
                @?= [ OfferedPreDescent "core:deploy-vm" "host-orchestrator-0"
                    , OfferedDescent "host-orchestrator-0" "vm-orchestrator-1"
                    , OfferedLocal "core:deploy-vm" DeleteFrame
                    ]
    , testCase "the ordinary branch carries the settled-child proof" $
        withDestroyForest $ \forest -> do
            -- Open reachability, then join the exact child subtree proof.
            let ready =
                    drainUntil
                        (== OfferedLocal "core:deploy-vm" DeleteFrame)
                        (attempt forest TeardownReleased)
            eliminateTeardownProgress
                (nextTeardownWork ready)
                (\_ -> assertFailure "the forest completed before the provider step")
                ( \point ->
                    withTeardownAuthorization
                        point
                        (\_ -> assertFailure "a second pre-descent step was offered")
                        ( \settled work -> do
                            settledChildrenKeys settled @?= ["core:build-pb"]
                            eliminateTeardownWork
                                work
                                (\local -> localWorkAction local @?= DeleteFrame)
                                (\_ -> assertFailure "the provider was classified as descent work")
                        )
                )
    , testCase "a failed descent blocks the exact child continuation as a unit" $
        withDestroyForest $ \forest -> do
            let reached = attempt forest TeardownReleased
                failedChart = attempt reached (TeardownFailed "helm uninstall timed out")
            -- The same exact edge is outstanding; no sibling raw outcome may
            -- bypass the missing child-subtree proof.
            firstWork failedChart
                @?= Just (OfferedDescent "host-orchestrator-0" "vm-orchestrator-1")
            teardownForestFailures failedChart
                @?= [ ("core:deploy-chart", "helm uninstall timed out")
                    , ("core:deploy-kind", "helm uninstall timed out")
                    , ("core:build-pb", "helm uninstall timed out")
                    ]
    , testCase "foreign and refused observations settle without being torn down" $
        withExactPlan forestContainerContext demoShapedPlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            let foreignChart = attempt forest (TeardownForeignRetained "an operator's release")
            teardownForestForeign foreignChart
                @?= [("core:deploy-chart", "an operator's release")]
            teardownForestFailures foreignChart @?= []
            firstWork foreignChart
                @?= Just (OfferedLocal "core:deploy-kind" DeleteCluster)
    , testCase "every attempt returns a successor forest, including a failure" $
        withDestroyForest $ \forest -> do
            let reached = attempt forest TeardownReleased
                failed = attempt reached (TeardownFailed "boom")
            assertBool
                "the failed node is no longer outstanding as pending work"
                ("core:deploy-chart" `elem` teardownForestOutstanding failed)
            length (teardownForestOutstanding failed) @?= 4
    ]
  where
    forestContainerContext root =
        Context.deriveContainerContext
            (Context.deriveVMContext root "/fixture/vm")
            "/fixture/container"

settlementTests :: [TestTree]
settlementTests =
    [ testCase "a completed destroy forest settles every projected identity" $
        withPlan $ \plan current -> do
            let projection = teardownPlan plan current ProjectDestroy
            forest <- openOrFail projection
            let expectedKeys = teardownForestOutstanding forest
            completed <- drainToCompletion forest
            case verifySubtreeSettled projection completed of
                Right subtree -> case verifyDestroySettled plan current subtree of
                    Right settled -> do
                        destroySettledPlanDigest settled @?= planDigestOf plan
                        terminalKeyTexts (destroySettledTerminalObservations settled)
                            @?= expectedKeys
                        terminalKeyTexts
                            [ (key, TeardownReleased)
                            | key <- destroySettledReleasedOperationKeys settled
                            ]
                            @?= expectedKeys
                    Left failure -> assertFailure (teardownErrorMessage failure)
                Left failure -> assertFailure (teardownErrorMessage failure)
    , testCase "a node that keeps failing keeps the forest from ever completing" $
        withDestroyForest $ \forest -> do
            let reached = attempt forest TeardownReleased
                failedChart = attempt reached (TeardownFailed "boom")
            eliminateTeardownProgress
                (nextTeardownWork failedChart)
                (\_ -> assertFailure "a forest with a failing descendant must not complete")
                ( \point ->
                    offeredWork point
                        @?= OfferedDescent "host-orchestrator-0" "vm-orchestrator-1"
                )
            teardownForestFailures failedChart
                @?= [ ("core:deploy-chart", "boom")
                    , ("core:deploy-kind", "boom")
                    , ("core:build-pb", "boom")
                    ]
            assertBool
                "the blocked parent chain is still outstanding"
                ( all
                    (`elem` teardownForestOutstanding failedChart)
                    ["core:deploy-chart", "core:build-pb", "core:deploy-vm"]
                )
    , testCase "a pre-descent foreign result cannot hide unobserved child nodes" $
        withPlan $ \plan current -> do
            let projection = teardownPlan plan current ProjectDestroy
            forest <- openOrFail projection
            let truncated = attempt forest (TeardownForeignRetained "provider is foreign")
            case nextTeardownWork truncated of
                progress ->
                    eliminateTeardownProgress
                        progress
                        ( \completed -> case verifySubtreeSettled projection completed of
                            Left (TeardownTerminalObservationsMismatch expected observed) -> do
                                expected
                                    @?= [ "core:deploy-chart"
                                        , "core:deploy-kind"
                                        , "core:build-pb"
                                        , "core:deploy-vm"
                                        ]
                                observed @?= ["core:deploy-vm"]
                            other -> assertFailure ("expected exact terminal mismatch, got " ++ show other)
                        )
                        (\_ -> assertFailure "the truncated forest should expose its malformed completion")
    , testCase "the exact child proof bulk-settles only its matching parent continuation" $
        withPlan $ \plan current -> do
            forest <- openOrFail (teardownPlan plan current ProjectDestroy)
            let reached = attempt forest TeardownReleased
            eliminateTeardownProgress
                (nextTeardownWork reached)
                (\_ -> assertFailure "the root forest completed before child descent")
                ( \point ->
                    withTeardownAuthorization
                        point
                        (\_ -> assertFailure "the child edge became pre-descent")
                        ( \_ work ->
                            eliminateTeardownWork
                                work
                                (\_ -> assertFailure "the child edge became local work")
                                ( \descent ->
                                    withDescentWorkSubtree descent $ \childProjection -> do
                                        teardownPlanFrameId childProjection @?= "vm-orchestrator-1"
                                        childForest <- openOrFail childProjection
                                        childCompleted <- drainToCompletion childForest
                                        childSettled <-
                                            either
                                                (assertFailure . teardownErrorMessage)
                                                pure
                                                (verifySubtreeSettled childProjection childCompleted)
                                        terminalKeyTexts
                                            (subtreeSettledTerminalObservations childSettled)
                                            @?= [ "core:deploy-chart"
                                                , "core:deploy-kind"
                                                , "core:build-pb"
                                                ]
                                        joined <-
                                            either
                                                (assertFailure . teardownErrorMessage)
                                                pure
                                                (settleDescentWork descent childSettled)
                                        firstWork joined
                                            @?= Just (OfferedLocal "core:deploy-vm" DeleteFrame)
                                )
                        )
                )
    , testCase "nested destroy settlement cannot promote to project-wide closure" $
        withExactPlan inVM demoShapedPlan $ \plan current -> do
            let projection = teardownPlan plan current ProjectDestroy
            forest <- openOrFail projection
            completed <- drainToCompletion forest
            subtree <-
                either
                    (assertFailure . teardownErrorMessage)
                    pure
                    (verifySubtreeSettled projection completed)
            case verifyDestroySettled plan current subtree of
                Left (TeardownRootFrameMismatch "vm-orchestrator-1" ["host-orchestrator-0"]) -> pure ()
                other -> assertFailure ("nested subtree promoted to root destroy: " ++ show other)
    , testCase "exact terminal validation rejects missing, extra, duplicate, reordered, and failed observations" $
        withPlan $ \plan current -> do
            let projection = teardownPlan plan current ProjectDestroy
                digest = planDigestOf plan
                frame = currentFrameId current
                keys =
                    reverse
                        [ plannedStepOperationKey step
                        | step <- NonEmpty.toList (forward plan)
                        , plannedStepReversePolicy step /= PreserveOnReverse
                        ]
                exact = [(key, TeardownReleased) | key <- keys]
                malformed =
                    [ ("missing", drop 1 exact)
                    , ("extra", exact ++ take 1 exact)
                    ,
                        ( "duplicate"
                        , case exact of
                            first : _second : rest -> first : first : rest
                            _ -> exact
                        )
                    ,
                        ( "reordered"
                        , case exact of
                            first : second : rest -> second : first : rest
                            _ -> exact
                        )
                    ]
            forM_ malformed $ \(label, observations) ->
                case verifySubtreeSettled projection (forgeCompleted ProjectDestroy digest frame observations) of
                    Left (TeardownTerminalObservationsMismatch _ _) -> pure ()
                    other -> assertFailure (label ++ " terminal sequence was accepted: " ++ show other)
            let failed = case exact of
                    (key, _) : rest -> (key, TeardownFailed "boom") : rest
                    [] -> []
            case verifySubtreeSettled projection (forgeCompleted ProjectDestroy digest frame failed) of
                Left (TeardownNonTerminalObservations _) -> pure ()
                other -> assertFailure ("failed terminal sequence was accepted: " ++ show other)
    ]
  where
    inVM root = Context.deriveVMContext root "/fixture/vm"

-- ---------------------------------------------------------------------------
-- Driving the forest

data OfferedWork
    = OfferedPreDescent Text Text
    | OfferedLocal Text TeardownAction
    | OfferedDescent Text Text
    deriving (Eq, Show)

{- | Test-only representation mirror used to adversarially exercise the
runtime exact-sequence checks behind the opaque constructor. Ordinary client
code is separately required to fail compilation when it tries to construct or
coerce a completion/proof.
-}
data CompletedShape verb
    = CompletedShape
        (ProjectVerb verb)
        Text
        Text
        [(OperationKey, TeardownOutcome)]

forgeCompleted ::
    ProjectVerb verb ->
    Text ->
    Text ->
    [(OperationKey, TeardownOutcome)] ->
    CompletedTeardownForest scope planId frame verb
forgeCompleted verb digest frame observations =
    unsafeCoerce (CompletedShape verb digest frame observations)

terminalKeyTexts :: [(OperationKey, TeardownOutcome)] -> [Text]
terminalKeyTexts = map (Text.pack . ProjectPlan.operationKeyText . fst)

driveWithOffered ::
    TeardownForest scope planId frame verb ->
    (OfferedWork -> IO TeardownOutcome) ->
    (Text -> TeardownOutcome -> IO ()) ->
    IO (Either [Text] (CompletedTeardownForest scope planId frame verb))
driveWithOffered forest attemptOffered =
    driveTeardownForest
        forest
        ( \pre ->
            attemptOffered
                (OfferedPreDescent (preDescentStepKey pre) (preDescentStepFrame pre))
        )
        ( \_ local ->
            attemptOffered (OfferedLocal (localWorkKey local) (localWorkAction local))
        )
        ( \_ descent ->
            do
                edge <-
                    attemptOffered
                        ( OfferedDescent
                            (descentWorkParentFrame descent)
                            (descentWorkChildFrame descent)
                        )
                case edge of
                    TeardownReleased ->
                        withDescentWorkSubtree descent $ \childProjection ->
                            case openTeardownForest childProjection of
                                Left failure -> pure (Left (Text.pack (teardownErrorMessage failure)))
                                Right childForest -> do
                                    childDriven <-
                                        driveWithOffered
                                            childForest
                                            attemptOffered
                                            (\_ _ -> pure ())
                                    pure $ case childDriven of
                                        Left outstanding ->
                                            Left
                                                ( "child subtree remained outstanding: "
                                                    <> Text.intercalate ", " outstanding
                                                )
                                        Right childCompleted ->
                                            either
                                                (Left . Text.pack . teardownErrorMessage)
                                                Right
                                                (verifySubtreeSettled childProjection childCompleted)
                    TeardownFailed detail -> pure (Left (Text.pack detail))
                    TeardownForeignRetained detail ->
                        pure (Left ("raw foreign descent cannot settle a subtree: " <> Text.pack detail))
                    TeardownRefused detail ->
                        pure (Left ("raw refused descent cannot settle a subtree: " <> Text.pack detail))
        )

offeredWork :: TeardownAuthorizationPoint scope planId frame verb -> OfferedWork
offeredWork point =
    withTeardownAuthorization
        point
        (\pre -> OfferedPreDescent (preDescentStepKey pre) (preDescentStepFrame pre))
        ( \_ work ->
            eliminateTeardownWork
                work
                (\local -> OfferedLocal (localWorkKey local) (localWorkAction local))
                ( \descent ->
                    OfferedDescent
                        (descentWorkParentFrame descent)
                        (descentWorkChildFrame descent)
                )
        )

advancePoint ::
    TeardownAuthorizationPoint scope planId frame verb ->
    TeardownOutcome ->
    TeardownForest scope planId frame verb
advancePoint point outcome =
    withTeardownAuthorization
        point
        (`attemptPreDescentStep` outcome)
        ( \_ work ->
            eliminateTeardownWork
                work
                (`attemptLocalWork` outcome)
                (\descent -> advanceDescent descent outcome)
        )

advanceDescent ::
    DescentWork scope planId frame childFrame verb ->
    TeardownOutcome ->
    TeardownForest scope planId frame verb
advanceDescent descent outcome = case outcome of
    TeardownReleased ->
        withDescentWorkSubtree descent $ \childProjection ->
            case openTeardownForest childProjection of
                Left failure -> failDescentWork descent (Text.pack (teardownErrorMessage failure))
                Right childForest ->
                    case completedAfterReleased childForest of
                        Left detail -> failDescentWork descent detail
                        Right childCompleted ->
                            case verifySubtreeSettled childProjection childCompleted of
                                Left failure ->
                                    failDescentWork descent (Text.pack (teardownErrorMessage failure))
                                Right childSettled ->
                                    either
                                        (failDescentWork descent . Text.pack . teardownErrorMessage)
                                        id
                                        (settleDescentWork descent childSettled)
    TeardownFailed detail -> failDescentWork descent (Text.pack detail)
    TeardownForeignRetained detail ->
        failDescentWork descent ("raw foreign descent cannot settle a subtree: " <> Text.pack detail)
    TeardownRefused detail ->
        failDescentWork descent ("raw refused descent cannot settle a subtree: " <> Text.pack detail)

completedAfterReleased ::
    TeardownForest scope planId frame verb ->
    Either Text (CompletedTeardownForest scope planId frame verb)
completedAfterReleased = go (0 :: Int)
  where
    go depth forest
        | depth > 64 = Left "released subtree traversal exceeded its finite bound"
        | otherwise =
            eliminateTeardownProgress
                (nextTeardownWork forest)
                Right
                (\point -> go (depth + 1) (advancePoint point TeardownReleased))

attempt ::
    TeardownForest scope planId frame verb ->
    TeardownOutcome ->
    TeardownForest scope planId frame verb
attempt forest outcome =
    eliminateTeardownProgress
        (nextTeardownWork forest)
        (const forest)
        (`advancePoint` outcome)

firstWork :: TeardownForest scope planId frame verb -> Maybe OfferedWork
firstWork forest =
    eliminateTeardownProgress
        (nextTeardownWork forest)
        (const Nothing)
        (Just . offeredWork)

localActionFor ::
    Text ->
    TeardownForest scope planId frame verb ->
    Maybe TeardownAction
localActionFor target = go (0 :: Int)
  where
    go depth forest
        | depth > 32 = Nothing
        | otherwise =
            eliminateTeardownProgress
                (nextTeardownWork forest)
                (const Nothing)
                ( \point ->
                    withTeardownAuthorization
                        point
                        (\pre -> go (depth + 1) (attemptPreDescentStep pre TeardownReleased))
                        ( \_ work ->
                            eliminateTeardownWork
                                work
                                ( \local ->
                                    if localWorkKey local == target
                                        then Just (localWorkAction local)
                                        else go (depth + 1) (attemptLocalWork local TeardownReleased)
                                )
                                ( \descent ->
                                    go (depth + 1) (advanceDescent descent TeardownReleased)
                                )
                        )
                )

-- | Release every offered step, recording the order they were offered in.
drainOrder :: TeardownForest scope planId frame verb -> [OfferedWork]
drainOrder = go (0 :: Int)
  where
    go depth forest
        | depth > 32 = []
        | otherwise =
            eliminateTeardownProgress
                (nextTeardownWork forest)
                (const [])
                ( \point ->
                    offeredWork point
                        : go (depth + 1) (advancePoint point TeardownReleased)
                )

-- | Release steps until the next offered branch satisfies the predicate.
drainUntil ::
    (OfferedWork -> Bool) ->
    TeardownForest scope planId frame verb ->
    TeardownForest scope planId frame verb
drainUntil matches = go (0 :: Int)
  where
    go depth forest
        | depth > 32 = forest
        | Just work <- firstWork forest
        , matches work =
            forest
        | otherwise = go (depth + 1) (attempt forest TeardownReleased)

-- | Release everything still offered.
drainAll :: TeardownForest scope planId frame verb -> TeardownForest scope planId frame verb
drainAll = go (0 :: Int)
  where
    go depth forest
        | depth > 32 = forest
        | otherwise =
            eliminateTeardownProgress
                (nextTeardownWork forest)
                (const forest)
                (\point -> go (depth + 1) (advancePoint point TeardownReleased))

drainToCompletion ::
    TeardownForest scope planId frame verb ->
    IO (CompletedTeardownForest scope planId frame verb)
drainToCompletion forest =
    eliminateTeardownProgress
        (nextTeardownWork (drainAll forest))
        pure
        ( \point ->
            assertFailure
                ("the forest did not complete; still offering " ++ show (offeredWork point))
        )

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

-- The worked demo has multiple host-local bootstrap nodes before the provider
-- and declares its two frame boundaries on later nodes. Its reverse forest is
-- the regression shape for preserving the flat projection's child-first order.
workedDemoReversePlan :: StepPlan
workedDemoReversePlan =
    mkPlan
        [ projectStep (demoStep "ensure-vm-provider") PreserveOnReverse "ensure" metalFrame noop
        , deployVMStep "launch" metalFrame noop
        , buildPbStep "build" metalFrame noop
        , descendsVia localContext (copySourceStep "share" metalFrame noop)
        , descendsVia localContext (contextInitStep "context" vmFrame noop)
        , deployKindStep "cluster" containerFrame noop
        , deployChartStep "chart" containerFrame noop
        ]

allPreservedPlan :: StepPlan
allPreservedPlan =
    mkPlan
        [ projectStep (demoStep "ensure-vm-provider") PreserveOnReverse "ensure" metalFrame noop
        ]

failedUpObservedPlan :: StepPlan
failedUpObservedPlan =
    mkPlan
        [ projectsOperation "project:ensure-vm-provider/guest-alias" $
            projectStep (demoStep "ensure-vm-provider") PreserveOnReverse "ensure" metalFrame noop
        , deployVMStep "launch" metalFrame noop
        ]

{- | The VM level exists in the exact topology but contributes no removable
reverse node. Descendant work opened at the root must still bind root→VM,
never skip directly to the container.
-}
emptyIntermediateReversePlan :: StepPlan
emptyIntermediateReversePlan =
    mkPlan
        [ descendsVia localContext (deployVMStep "launch" metalFrame noop)
        , descendsVia
            localContext
            (projectStep (demoStep "preserved-vm-bridge") PreserveOnReverse "bridge" vmFrame noop)
        , deployChartStep "chart" containerFrame noop
        ]

executableContainerPlan :: IORef [(Text, TeardownAction)] -> StepPlan
executableContainerPlan observed =
    mkPlan
        [ descendsVia localContext (deployVMStep "launch" metalFrame noop)
        , descendsVia localContext (buildPbStep "build" vmFrame noop)
        , reversedBy
            ( \_cfg action -> do
                modifyIORef' observed (++ [("core:deploy-chart", action)])
                pure TeardownReleased
            )
            (deployChartStep "chart" containerFrame noop)
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
    IO (TeardownForest scope planId frame verb)
openOrFail projection =
    either (assertFailure . teardownErrorMessage) pure (openTeardownForest projection)

withDestroyForest ::
    ( forall projectId planId frame.
      TeardownForest (Production projectId) planId frame VerbDestroy ->
      IO ()
    ) ->
    IO ()
withDestroyForest use =
    withPlan $ \plan current -> openOrFail (teardownPlan plan current ProjectDestroy) >>= use

withDownForest ::
    ( forall projectId planId frame.
      TeardownForest (Production projectId) planId frame VerbDown ->
      IO ()
    ) ->
    IO ()
withDownForest use =
    withPlan $ \plan current -> openOrFail (teardownPlan plan current ProjectDown) >>= use

assertPlanSuffix ::
    (Context.BinaryContext -> Context.BinaryContext) ->
    Text ->
    [Text] ->
    IO ()
assertPlanSuffix selectContext expectedFrame expectedKeys =
    withExactPlan selectContext demoShapedPlan $ \plan current -> do
        let projection = teardownPlan plan current ProjectDestroy
        forest <- openOrFail projection
        currentFrameId current @?= expectedFrame
        teardownPlanFrameId projection @?= expectedFrame
        teardownForestOutstanding forest @?= expectedKeys

assertFirstOrdinaryPlacement ::
    (Context.BinaryContext -> Context.BinaryContext) ->
    StepPlan ->
    OfferedWork ->
    IO ()
assertFirstOrdinaryPlacement selectContext stepPlan expected =
    withExactPlan selectContext stepPlan $ \plan current -> do
        forest <- openOrFail (teardownPlan plan current ProjectDestroy)
        firstOrdinary (0 :: Int) forest @?= Just expected
  where
    firstOrdinary depth forest
        | depth > 4 = Nothing
        | otherwise = case firstWork forest of
            Just (OfferedPreDescent _ _) ->
                firstOrdinary (depth + 1) (attempt forest TeardownReleased)
            offered -> offered

describeOpen :: Either TeardownError (TeardownForest scope planId frame verb) -> String
describeOpen = either teardownErrorMessage (const "an opened forest")
