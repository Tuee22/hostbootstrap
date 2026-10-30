{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ReadinessSpec (tests) where

import Control.Monad (forM_)
import Data.Foldable (find)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Lift (localContext)
import HostBootstrap.ProjectPlan (PlannedResource, ProviderResource)
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import HostBootstrap.Readiness
import HostBootstrap.Readiness.Kernel (withBackendProbe)
import qualified HostBootstrap.Reconcile as Reconcile
import HostBootstrap.Step (
    StepFrame (StepFrame),
    StepObservation (StepChanged),
    StepPlan,
    copySourceStep,
    deployVMStep,
    descendsVia,
    mkStepPlan,
 )
import HostBootstrap.Substrate (Arch (Arm64), Substrate (..), SubstrateName (LinuxCpu))
import PrepareFixture (gateFor)
import qualified SourceGuard
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "ReadinessSpec"
        [ testGroup "validated policies" policyCases
        , testGroup "total pollStep" pollStepCases
        , testGroup "bounded IO polling" pollingCases
        , testCase "indexed readiness retains versions reported at await time" indexedReadinessCase
        , testGroup "zero reported versions" invalidIndexedProbeCases
        , testGroup "managed dependency readiness" dependencyReadinessCases
        , testCase "polling has no second driver or partial named-policy builder" pollingDefinitionsCase
        ]

fiveSeconds :: Micros
fiveSeconds = rightOrFail (seconds 5)

zeroDelayPolicy :: PollPolicy
zeroDelayPolicy = rightOrFail (seconds 0 >>= mkPollPolicy 3)

policyCases :: [TestTree]
policyCases =
    [ namedPolicyCase "rollout" rolloutPoll 6 5 5000000
    , namedPolicyCase "push" pushPoll 4 5 5000000
    , namedPolicyCase "reach" reachPoll 24 5 5000000
    , namedPolicyCase "VM boot" vmBootPoll 60 2 2000000
    , namedPolicyCase "network" networkPoll 20 3 3000000
    , namedPolicyCase "Docker" dockerPoll 30 2 2000000
    , namedPolicyCase "node" nodePoll 10 3 3000000
    , testCase "seconds converts to absolute microseconds" $
        (microsValue <$> seconds 5) @?= Right 5000000
    , testCase "attempt override is validated and preserves delay" $ do
        let adjusted = withAttempts reachPoll 12
        fmap pollAttempts adjusted @?= Right 12
        fmap pollDelay adjusted @?= Right fiveSeconds
    , testCase "schedule contains attempts minus one gaps" $ do
        pollSchedule rolloutPoll @?= replicate 5 fiveSeconds
        fmap pollSchedule (mkPollPolicy 1 fiveSeconds) @?= Right []
    , testCase "zero attempts are refused exactly" $
        mkPollPolicy 0 fiveSeconds @?= Left ZeroAttempts
    , testCase "negative delay is refused exactly" $
        seconds (-1) @?= Left (NegativeDelay (-1))
    , testCase "delay overflow is refused exactly" $
        seconds (toInteger (maxBound :: Int))
            @?= Left (DelayOverflow (toInteger (maxBound :: Int)))
    , testCase "attempt limit is refused exactly" $
        (seconds 0 >>= mkPollPolicy 1000001) @?= Left (AttemptsTooLarge 1000001)
    , testCase "total duration overflow is refused exactly" $
        (seconds 9000000000000 >>= mkPollPolicy 3) @?= Left TotalDurationOverflow
    , testCase "total duration limit is refused exactly" $
        (seconds 86401 >>= mkPollPolicy 2) @?= Left (TotalDurationTooLarge 86401000000)
    ]
  where
    namedPolicyCase label policy attempts delaySeconds expectedMicros =
        testCase (label ++ " policy retains its exact budget") $ do
            Right policy @?= (seconds delaySeconds >>= mkPollPolicy attempts)
            pollAttempts policy @?= attempts
            microsValue (pollDelay policy) @?= expectedMicros

pollStepCases :: [TestTree]
pollStepCases =
    [ testCase "ready yields immediately" $
        pollStep rolloutPoll "l" 0 (ProbeReady 'x') @?= Yield 'x'
    , testCase "transient not-ready retries" $
        pollStep rolloutPoll "l" 0 (NotReady "starting" :: ProbeResult ())
            @?= Retry fiveSeconds
    , testCase "last transient result times out with observation" $
        pollStep rolloutPoll "l" 5 (NotReady "starting" :: ProbeResult ())
            @?= GiveUp (PollTimeout "l" "starting")
    , testCase "unavailable stops immediately" $
        pollStep rolloutPoll "l" 0 (Unavailable "wrong substrate" :: ProbeResult ())
            @?= GiveUp (PollUnavailable "l" "wrong substrate")
    , testCase "conflict stops immediately with structure" $
        let conflict = ProbeConflict "generation-1" "generation-2" "remove the foreign resource"
         in pollStep rolloutPoll "l" 0 (ProbeConflicted conflict :: ProbeResult ())
                @?= GiveUp (PollConflict "l" conflict)
    , testCase "deterministic failure stops immediately" $
        let failure = ProbeFailure "docker info" "permission denied"
         in pollStep rolloutPoll "l" 0 (Failed failure :: ProbeResult ())
                @?= GiveUp (PollFailed "l" failure)
    ]

pollingCases :: [TestTree]
pollingCases =
    [ testCase "real polling converges after two recoveries" $ do
        (result, probes, recoveries, remaining) <-
            runScript [NotReady "a", NotReady "b", ProbeReady (42 :: Int)]
        result @?= Right 42
        probes @?= 3
        recoveries @?= 2
        remaining @?= []
    , testCase "real polling exhausts exactly three attempts" $ do
        (result, probes, recoveries, remaining) <-
            runScript [NotReady "a", NotReady "b", NotReady "still starting", ProbeReady ()]
        result @?= Left (PollTimeout "provider" "still starting")
        probes @?= 3
        recoveries @?= 2
        remaining @?= [ProbeReady ()]
    , testCase "real polling stops at failure without another probe" $ do
        let failure = ProbeFailure "probe" "nope"
        (result, probes, recoveries, remaining) <-
            runScript [Failed failure, ProbeReady ()]
        result @?= Left (PollFailed "provider" failure)
        probes @?= 1
        recoveries @?= 0
        remaining @?= [ProbeReady ()]
    ]

runScript :: [ProbeResult a] -> IO (Either PollError a, Int, Int, [ProbeResult a])
runScript observations = do
    script <- newIORef observations
    probes <- newIORef 0
    recoveries <- newIORef 0
    let runProbe _ = do
            modifyIORef' probes (+ 1)
            next <- atomicModifyIORef' script $ \remaining -> case remaining of
                [] -> ([], Nothing)
                observation : rest -> (rest, Just observation)
            maybe (fail "polling exceeded the scripted observations") pure next
        recover _ = modifyIORef' recoveries (+ 1)
    result <- pollUntilReadyWith zeroDelayPolicy "provider" recover runProbe fixtureHostConfig
    probeCount <- readIORef probes
    recoveryCount <- readIORef recoveries
    remaining <- readIORef script
    pure (result, probeCount, recoveryCount, remaining)

indexedReadinessCase :: IO ()
indexedReadinessCase =
    runPlannedProbe $ \planned -> do
        report <- newIORef (BackendReady 1 2 3 ())
        withBackendProbe
            ProviderRespondingProbe
            planned
            (const (ProbeReady <$> readIORef report))
            ( \probe -> do
                writeIORef report (BackendReady 7 11 13 ())
                result <- awaitPlanReady zeroDelayPolicy "provider" probe fixtureHostConfig
                fmap readyVersions result @?= Right (7, 11, 13)
            )

invalidIndexedProbeCases :: [TestTree]
invalidIndexedProbeCases =
    [ invalidVersionCase "generation" (BackendReady 0 11 13 ()) ZeroProbeGeneration
    , invalidVersionCase "phase version" (BackendReady 7 0 13 ()) ZeroProbePhaseVersion
    , invalidVersionCase "observation version" (BackendReady 7 11 0 ()) ZeroProbeObservationVersion
    ]
  where
    invalidVersionCase label report expected =
        testCase ("zero " ++ label ++ " is refused at await time") $
            runPlannedProbe $ \planned ->
                withBackendProbe
                    ProviderRespondingProbe
                    planned
                    (const (pure (ProbeReady report)))
                    ( \probe -> do
                        result <- awaitPlanReady zeroDelayPolicy "provider" probe fixtureHostConfig
                        fmap readyVersions result @?= Left (PollInvalidReady "provider" expected)
                    )

readyVersions :: Ready scope planId resourceId resource dependency -> (Word64, Word64, Word64)
readyVersions ready =
    (readyGeneration ready, readyPhaseVersion ready, readyObservationVersion ready)

dependencyReadinessCases :: [TestTree]
dependencyReadinessCases =
    [ testCase "matching managed readiness seals the declared dependency" $
        runDependencyProbe (ProbeReady (BackendReady 5 17 7 ()))
            >>= (@?= Right ["core:deploy-vm"])
    , testCase "stale managed generation refuses during snapshot traversal" $
        runDependencyProbe (ProbeReady (BackendReady 9 17 7 ()))
            >>= ( @?=
                    Left
                        ( Reconcile.Conflict
                            ( Reconcile.ConflictDetail
                                "core:deploy-vm"
                                "generation=5"
                                "ready generation=9"
                                "reprobe readiness for the exact managed generation"
                            )
                        )
                )
    , testCase "stale managed observation refuses during snapshot traversal" $
        runDependencyProbe (ProbeReady (BackendReady 5 17 9 ()))
            >>= ( @?=
                    Left
                        ( Reconcile.Conflict
                            ( Reconcile.ConflictDetail
                                "core:deploy-vm"
                                "observation version=7"
                                "ready observation version=9"
                                "reprobe the dependency and readiness from one snapshot"
                            )
                        )
                )
    , testCase "managed readiness timeout requires a fresh probe" $
        runDependencyProbe (NotReady "starting")
            >>= ( @?=
                    Left
                        ( Reconcile.Failure
                            ( Reconcile.FailureDetail
                                "probe dependency provider"
                                "provider: did not become ready within the poll budget (starting)"
                                Reconcile.ReprobeBeforeRetry
                            )
                        )
                )
    ]

-- The share's real plan edge forces the registered provider probe to run.
runDependencyProbe :: ProbeResult (BackendReady ()) -> IO (Either Reconcile.ReconcileError [Text.Text])
runDependencyProbe observation =
    Fixture.withFixtureProjectPlan dependentTestPlan $ \projectPlan -> do
        providerKey <- requireOperationKey "core:deploy-vm" projectPlan
        shareKey <- requireOperationKey "core:copy-source" projectPlan
        let plan = Reconcile.lifecyclePlanFromProjectPlan projectPlan
        providerGate <- gateFor (Reconcile.lifecyclePlanDigest plan) "core:deploy-vm"
        case ProjectPlan.withPlannedResourceOfKind
            projectPlan
            ProjectPlan.ProviderResourceKind
            providerKey
            ( \provider ->
                ProjectPlan.withPlannedResourceOfKind
                    projectPlan
                    ProjectPlan.DurableShareResourceKind
                    shareKey
                    ( \share ->
                        joinIO $
                            withManagedProvider providerGate plan provider $ \managed ->
                                joinIO $
                                    Reconcile.withObservedPlannedResource plan share 11 13 $ \shareHandle ->
                                        case Reconcile.plannedOperation plan share shareHandle "share:mount" of
                                            Left failure -> pure (Left failure)
                                            Right descriptor ->
                                                withBackendProbe
                                                    ProviderRespondingProbe
                                                    provider
                                                    (const (pure observation))
                                                    ( \probe ->
                                                        fmap (fmap Reconcile.operationPreconditionKeys) $
                                                            Reconcile.withOperationPreconditions
                                                                descriptor
                                                                ( Reconcile.withDependencySnapshotEntry
                                                                    managed
                                                                    (planDependencyProbe zeroDelayPolicy "provider" managed probe fixtureHostConfig)
                                                                    Reconcile.emptyDependencySnapshot
                                                                )
                                                    )
                    )
            ) of
            Left failure -> fail (show failure)
            Right (Left failure) -> fail (show failure)
            Right (Right action) -> action

withManagedProvider ::
    PreparedGate ->
    Reconcile.LifecyclePlan scope planId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    (Reconcile.ResourceHandle scope planId providerId ProviderResource Reconcile.Managed Reconcile.Provisioned -> result) ->
    Either Reconcile.ReconcileError result
withManagedProvider gate plan planned consume =
    joinReconcile $
        Reconcile.withObservedPlannedResource plan planned 5 7 $ \observed -> do
            descriptor <- Reconcile.plannedOperation plan planned observed "provider:create"
            preconditionSet <- Reconcile.zeroDependencyPreconditions descriptor
            joinReconcile $
                Reconcile.withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
                    reconciled <- Reconcile.completeReconcile observed prepared preconditions (Reconcile.BackendCreated 5)
                    Reconcile.withReconcileResult
                        reconciled
                        (\managed _ _ -> Right (consume managed))
                        (\_ _ -> Left (Reconcile.Failure (Reconcile.FailureDetail "test provider" "unexpected foreign provider" Reconcile.DoNotRetry)))

joinReconcile :: Either Reconcile.ReconcileError (Either Reconcile.ReconcileError a) -> Either Reconcile.ReconcileError a
joinReconcile = either Left id

joinIO :: Either Reconcile.ReconcileError (IO (Either Reconcile.ReconcileError a)) -> IO (Either Reconcile.ReconcileError a)
joinIO = either (pure . Left) id

pollingDefinitionsCase :: IO ()
pollingDefinitionsCase =
    -- DEVELOPMENT_PLAN/rationale.md: "Tests drive the production polling loop".
    SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
        description <- SourceGuard.readPackageDescription
        sources <- SourceGuard.readLibrarySources packageRoot description
        forM_ sources $ \(name, path, source) -> do
            definitions <-
                either
                    (assertFailure . ((name ++ ": ") ++))
                    pure
                    (SourceGuard.haskellDefinitionNames source)
            forM_ ["drivePure", "namedPolicy"] $ \identifier ->
                assertBool
                    (identifier ++ " is defined by " ++ name ++ " at " ++ SourceGuard.repoRelativePath packageRoot path)
                    (identifier `notElem` definitions)

fixtureHostConfig :: HostConfig
fixtureHostConfig =
    HostConfig
        { hcSubstrate = Substrate{substrateName = LinuxCpu, substrateArch = Arm64}
        , hcToolPaths = Map.empty
        }

rightOrFail :: (Show e) => Either e a -> a
rightOrFail = either (error . show) id

testPlan :: StepPlan
testPlan =
    rightOrFail $
        mkStepPlan [deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged))]

dependentTestPlan :: StepPlan
dependentTestPlan =
    rightOrFail $
        mkStepPlan
            [ descendsVia localContext (deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged)))
            , copySourceStep "durable share" (StepFrame "provider" "VM") (const (pure StepChanged))
            ]

runPlannedProbe ::
    ( forall projectId planId resourceId frame.
      PlannedResource
        (Production projectId)
        planId
        resourceId
        ProviderResource
        frame ->
      IO ()
    ) ->
    IO ()
runPlannedProbe consume =
    Fixture.withFixtureProjectPlan testPlan $ \projectPlan -> do
        providerKey <- requireOperationKey "core:deploy-vm" projectPlan
        case ProjectPlan.withPlannedResourceOfKind
            projectPlan
            ProjectPlan.ProviderResourceKind
            providerKey
            consume of
            Left err -> assertBool ("expected planned resource, got " ++ show err) False
            Right assertion -> assertion

requireOperationKey ::
    Text.Text ->
    ProjectPlan.ProjectPlan scope specDigest planId configId cfg ->
    IO ProjectPlan.OperationKey
requireOperationKey expected projectPlan =
    case find
        ( (== Text.unpack expected)
            . ProjectPlan.operationKeyText
            . ProjectPlan.plannedStepOperationKey
        )
        (ProjectPlan.forward projectPlan) of
        Just plannedStep -> pure (ProjectPlan.plannedStepOperationKey plannedStep)
        Nothing -> fail ("fixture project plan lacks operation " ++ Text.unpack expected)
