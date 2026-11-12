{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module BudgetSpec (tests) where

import CompileFailSpec (withPrivateBudgetKernel)
import Control.Monad (forM, forM_)
import qualified Data.ByteString as ByteString
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Cluster.Budget
import HostBootstrap.Cluster.Cordon
import qualified HostBootstrap.Cluster.Cordon.Foundation as BudgetRenderer
import HostBootstrap.Cluster.Workload.Binding (withMatchingChartWorkloadDeclaration)
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.Lifecycle.Prepared (PreparedGate, preparedGateCommitment)
import HostBootstrap.Lift (localContext)
import HostBootstrap.ProjectPlan (
    ClusterResource,
    DerivedTopology,
    PlannedResource,
    PlannedResourceKind (ClusterResourceKind, ProviderResourceKind),
    ProjectPlan,
    ProviderResource,
    forward,
    plannedResourceFrame,
    plannedResourceKey,
    plannedStepOperationKey,
    renderSnapshot,
    stablePlanSnapshotDigest,
    topology,
    topologyFrameOrder,
    withChartWorkloadResource,
    withPlannedResourceOfKind,
 )
import HostBootstrap.Reconcile (
    ReconcileError (..),
    UnsupportedDetail (..),
 )
import HostBootstrap.Step (
    StepFrame (StepFrame),
    StepObservation (StepChanged),
    ReversePolicy (ProjectManagedReverse),
    StepPlan,
    contextInitStep,
    declaresChartWorkloadResource,
    deployChartStep,
    deployKindStep,
    deployVMStep,
    descendsVia,
    declaresProviderResource,
    providerResourceAtCurrentFrame,
    projectStep,
    projectStepId,
    mkStepPlan,
 )
import Numeric.Natural (Natural)
import PrepareFixture (gateFor, gateForValues)
import SealedExportInventory (pinnedPrivateExportLists)
import qualified SourceGuard
import System.FilePath ((</>))
import System.Exit (ExitCode (ExitSuccess))
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Unsafe.Coerce (unsafeCoerce)

privateWallSettlementCases :: TestTree
privateWallSettlementCases =
    withPrivateBudgetKernel privateWallSettlementSource $ \getExecutable ->
        testGroup "private provider-wall settlement"
            [ testCase label $ do
                executable <- getExecutable
                (code, output, diagnostic) <- readProcessWithExitCode executable [argument] ""
                assertBool ("private Budget kernel failed:\n" <> output <> diagnostic) (code == ExitSuccess)
                assertBool (output <> diagnostic) (null diagnostic)
            | (label, argument) <-
                [ ("a migrated wall settles its positive epoch as Repaired", "migrated")
                , ("a zero-epoch migrated wall is refused at the mint", "zero-migrated")
                , ("a WSL wall settles only through the global-wall lease continuation", "wsl")
                , ("a Colima wall settles through the ordinary continuation", "ordinary")
                , ("non-owning observations are refused before producing live authority", "non-owning")
                , ("storage settlement preserves the exact wall epoch and change", "storage-success")
                , ("storage settlement rejects ceiling and epoch drift", "storage-drift")
                , ("storage non-success observations cannot invoke the consumer", "storage-refusals")
                , ("storage permits refuse a different journal or wall fence", "storage-fence")
                ]
            ]

budgetKernelImportCase :: IO ()
budgetKernelImportCase =
    SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
        paths <- concat <$> mapM (SourceGuard.listHaskellSources . (packageRoot </>)) ["src", "internal", "app"]
        sources <- forM paths $ \path -> do
            source <- Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile path
            pure (SourceGuard.repoRelativePath packageRoot path, source)
        let kernel = "HostBootstrap.Cluster.Budget.Internal"
            importing = sort [path | (path, source) <- sources, SourceGuard.importsModule kernel source]
            budget = "src/HostBootstrap/Cluster/Budget.hs"
            bridge = "src/HostBootstrap/Ensure/Colima.hs"
        importing @?= [budget, bridge]
        bridgeSource <- maybe (assertFailure "the owning Colima bridge source is absent") pure (lookup bridge sources)
        tokens <- maybe (assertFailure "the bridge must import an explicit private-kernel list") pure (SourceGuard.moduleImportTokens kernel bridgeSource)
        forM_ ["ProviderWallReservation", "PreparedProviderWallCall"] $ \constructor ->
            assertBool ("the bridge imports an authority constructor: " <> constructor) (constructor `notElem` tokens)

privateWallSettlementSource :: String
privateWallSettlementSource =
    unlines
        [ "{-# LANGUAGE OverloadedStrings #-}"
        , "module Main (main) where"
        , "import Control.Monad (forM_)"
        , "import Data.IORef (newIORef, readIORef, writeIORef)"
        , "import qualified HostBootstrap.Cluster.Cordon.Foundation as Cordon"
        , "import qualified Data.List.NonEmpty as NonEmpty"
        , "import Data.Word (Word64)"
        , "import qualified Data.Text as Text"
        , "import Fixture (withFixtureProjectPlan)"
        , "import HostBootstrap.Cluster.Budget"
        , "import qualified HostBootstrap.Cluster.Budget.Internal as Internal"
        , "import HostBootstrap.Lifecycle.Prepared"
        , "import HostBootstrap.ProjectPlan"
        , "import HostBootstrap.Reconcile hiding (plannedResourceKey)"
        , "import HostBootstrap.Step"
        , "import PrepareFixture (gateForValues)"
        , "import System.Environment (getArgs)"
        , "import Test.Tasty.HUnit ((@?=), assertFailure)"
        , ""
        , "main :: IO ()"
        , "main = do"
        , "    arguments <- getArgs"
        , "    case arguments of"
        , "        [\"migrated\"] -> runCase ColimaBackend (WallMigrated 7 \"resized\") (Right (7, Changed Repaired, False))"
        , "        [\"zero-migrated\"] -> runCase ColimaBackend (WallMigrated 0 \"resized\") (refused \"invalid epoch\")"
        , "        [\"wsl\"] -> runCase Wsl2Backend (WallApplied 7) (Right (7, Changed Created, True))"
        , "        [\"ordinary\"] -> runCase ColimaBackend (WallAlreadyExact 7) (Right (7, Unchanged, False))"
        , "        [\"non-owning\"] -> forM_"
        , "            [(WallApplied 0, \"invalid epoch\"), (WallAlreadyExact 0, \"invalid epoch\")"
        , "            , (WallRefused (ConflictDetail \"wall\" \"owned\" \"foreign\" \"stop\"), \"conflict\")"
        , "            , (WallAcquireFailed (FailureDetail \"wall\" \"failed\" DoNotRetry), \"failure\")"
        , "            , (WallAcquireUncertain \"unknown\", \"uncertain\")]"
        , "            (\\(observation, reason) -> runCase ColimaBackend observation (refused reason))"
        , "        [\"storage-success\"] -> do"
        , "            runStorageCase (Internal.StorageWallApplied 7 ceilingBytes) (Right (Changed Created))"
        , "            runStorageCase (Internal.StorageWallAlreadyExact 7 ceilingBytes) (Right Unchanged)"
        , "        [\"storage-drift\"] -> do"
        , "            runStorageCase (Internal.StorageWallApplied 0 ceilingBytes) (Left (Failure (FailureDetail \"apply storage wall\" \"wall epoch must be positive\" DoNotRetry)))"
        , "            runStorageCase (Internal.StorageWallApplied 8 ceilingBytes) (Left (Conflict (ConflictDetail \"storage-wall\" \"the live provider wall epoch\" \"8\" \"observe the exact live provider wall\")))"
        , "            runStorageCase (Internal.StorageWallApplied 7 (128 * gib)) (Left (Conflict (ConflictDetail \"storage-wall\" (Text.pack (show ceilingBytes) <> \" bytes\") (Text.pack (show (128 * gib)) <> \" bytes\") \"the provider did not apply the declared storage ceiling exactly; a rounded hard ceiling is never accepted\")))"
        , "        [\"storage-refusals\"] -> do"
        , "            let conflict = ConflictDetail \"storage\" \"owned\" \"foreign\" \"stop\""
        , "                failure = FailureDetail \"storage\" \"failed\" DoNotRetry"
        , "            runStorageCase (Internal.StorageWallRefused conflict) (Left (Conflict conflict))"
        , "            runStorageCase (Internal.StorageWallFailed failure) (Left (Failure failure))"
        , "            runStorageCase (Internal.StorageWallUncertain \"unknown\") (Left (Failure (FailureDetail \"apply storage wall\" \"unknown\" ReprobeBeforeRetry)))"
        , "        [\"storage-fence\"] -> do"
        , "            runStorageMismatch True False"
        , "            runStorageMismatch False True"
        , "        _ -> assertFailure \"expected a provider-wall settlement control case\""
        , "  where"
        , "    refused reason = Left (Failure (FailureDetail \"settle provider wall\""
        , "        (\"the owning provider adapter returned a non-owning \" <> reason <> \" observation\") DoNotRetry))"
        , ""
        , "runCase :: ProviderBackend -> WallAcquireObservation -> Either ReconcileError (Word64, ChangeView, Bool) -> IO ()"
        , "runCase backend observation expected ="
        , "    withFixtureProjectPlan providerPlan $ \\plan ->"
        , "        case NonEmpty.toList (forward plan) of"
        , "            [node] -> either (assertFailure . show) id $"
        , "                withPlannedResourceOfKind plan ProviderResourceKind (plannedStepOperationKey node) $ \\provider -> do"
        , "                    let digest = stablePlanSnapshotDigest (renderSnapshot plan)"
        , "                        operationKey = plannedResourceKey provider"
        , "                    gate <- gateForValues digest operationKey \"session-1\" 7 3"
        , "                    let result = joinResult $ withObservedProjectResource plan provider 19 2 $ \\observed -> do"
        , "                            descriptor <- plannedProjectOperation plan provider observed \"wall:acquire\""
        , "                            joinResult $ withPreparedZeroDependencyOperation descriptor gate $ \\operation preconditions ->"
        , "                                Internal.withProviderKeyForBackend backend $ \\providerKey ->"
        , "                                    let call = Internal.PreparedProviderWallCall providerKey [\"fixture-call\"] digest operationKey"
        , "                                            (preparedGateSession gate) (preparedGateFence gate) (preparedGateAttempt gate) (preparedGateJournalVersion gate)"
        , "                                    in joinResult $ Internal.withProviderWallSettlementPermitFromObservation"
        , "                                        call gate operation preconditions observation $ \\permit ->"
        , "                                            settleProviderWallCall call permit $ \\live -> withLiveProviderWall live"
        , "                                                (\\authority change -> (providerWallEpoch authority, change, False))"
        , "                                                (\\authority _lease change -> (providerWallEpoch authority, change, True))"
        , "                    result @?= expected"
        , "            nodes -> assertFailure (\"expected one provider operation, got \" <> show (length nodes))"
        , "  where"
        , "    providerPlan = either (error . show) id $ mkStepPlan"
        , "        [deployVMStep \"provider\" (StepFrame \"host\" \"Host\") (const (pure StepChanged))]"
        , "    joinResult = either Left id"
        , ""
        , "gib :: Integer"
        , "gib = 1024 ^ (3 :: Integer)"
        , "ceilingBytes :: Integer"
        , "ceilingBytes = 100 * gib"
        , ""
        , "runStorageCase :: Internal.StorageWallObservation -> Either ReconcileError ChangeView -> IO ()"
        , "runStorageCase observation expected = runStorageCheck False False observation (Just expected)"
        , ""
        , "runStorageMismatch :: Bool -> Bool -> IO ()"
        , "runStorageMismatch wrongGate wrongWall = runStorageCheck wrongGate wrongWall (Internal.StorageWallApplied 7 ceilingBytes) Nothing"
        , ""
        , "runStorageCheck :: Bool -> Bool -> Internal.StorageWallObservation -> Maybe (Either ReconcileError ChangeView) -> IO ()"
        , "runStorageCheck wrongGate wrongWall observation expected ="
        , "    withFixtureProjectPlan providerPlan $ \\plan ->"
        , "        case NonEmpty.toList (forward plan) of"
        , "            [node] -> either (assertFailure . show) id $"
        , "                withPlannedResourceOfKind plan ProviderResourceKind (plannedStepOperationKey node) $ \\provider -> do"
        , "                    marker <- newIORef False"
        , "                    let digest = stablePlanSnapshotDigest (renderSnapshot plan)"
        , "                        operationKey = plannedResourceKey provider"
        , "                    gate <- gateForValues digest operationKey \"session-1\" 7 3"
        , "                    otherGate <- gateForValues digest operationKey \"session-1\" 8 3"
        , "                    let result = joinResult $ withObservedProjectResource plan provider 19 2 $ \\observed -> do"
        , "                            descriptor <- plannedProjectOperation plan provider observed \"wall:acquire\""
        , "                            joinResult $ withPreparedZeroDependencyOperation descriptor gate $ \\operation preconditions ->"
        , "                                let call = Internal.PreparedProviderWallCall Internal.LimaProviderKey [\"fixture-call\"] digest operationKey"
        , "                                        (preparedGateSession gate) (preparedGateFence gate) (preparedGateAttempt gate) (preparedGateJournalVersion gate)"
        , "                                    reservation = Internal.ProviderWallReservation digest operationKey (preparedGateSession gate)"
        , "                                        (preparedGateFence gate) (preparedGateAttempt gate) (preparedGateJournalVersion gate)"
        , "                                    storage = Internal.PreparedStorageWallCall Cordon.LimaDiskFlag [\"--disk\", \"100\"] ceilingBytes reservation"
        , "                                    consume authority = let chosenGate = if wrongGate then otherGate else gate; chosenWall = if wrongWall then Internal.ProviderWallAuthority 7 8 else authority"
        , "                                        in joinResult $ Internal.withStorageWallSettlementPermitFromObservation storage chosenGate chosenWall observation $ \\permit ->"
        , "                                            settleStorageWallCall storage chosenWall permit (\\wall -> writeIORef marker True >> pure (appliedStorageWallChange wall))"
        , "                                in joinResult $ Internal.withProviderWallSettlementPermitFromObservation call gate operation preconditions (WallApplied 7) $ \\permit ->"
        , "                                    settleProviderWallCall call permit $ \\live -> withLiveProviderWall live"
        , "                                        (\\authority _ -> consume authority)"
        , "                                        (\\_ _ _ -> Left (Failure (FailureDetail \"test\" \"unexpected WSL wall\" DoNotRetry)))"
        , "                    actual <- either (pure . Left) (fmap Right) (joinResult result)"
        , "                    case expected of"
        , "                        Just value -> actual @?= value"
        , "                        Nothing -> case actual of"
        , "                            Left (Conflict detail) -> conflictExpected detail @?= \"the prepared storage call and live wall fence\""
        , "                            _ -> assertFailure (\"expected a lineage or fence conflict, got \" ++ show actual)"
        , "                    invoked <- readIORef marker"
        , "                    invoked @?= maybe False (either (const False) (const True)) expected"
        , "            nodes -> assertFailure (\"expected one provider operation, got \" <> show (length nodes))"
        , "  where"
        , "    providerPlan = either (error . show) id $ mkStepPlan"
        , "        [deployVMStep \"provider\" (StepFrame \"host\" \"Host\") (const (pure StepChanged))]"
        , "    joinResult = either Left id"
        ]

gib :: Integer
gib = 1024 ^ (3 :: Integer)

exactEnvelope :: ResourceEnvelope
exactEnvelope = ResourceEnvelope 8 "16GiB" "100GiB"

tests :: TestTree
tests =
    testGroup
        "BudgetSpec"
        [ testCase "provider admission rejects upward rounding" $ do
            let inexact = ResourceEnvelope 4 "8589934593" "20GiB"
            result <- admissionSummary inexact LimaBackend
            result @?= Left (InexactProviderQuantity LimaBackend "memory" (8 * gib + 1))
        , testCase "Colima admission reserves its fixed writable root disk inside the declared ceiling" $ do
            result <- admissionSummary (ResourceEnvelope 8 "16GiB" "20GiB") ColimaBackend
            result
                @?= Left
                    ( InvalidBudget
                        "Colima storage must exceed the fixed 20 GiB writable root disk; got 20 GiB"
                    )
        , testCase "provider wall argv consumes admitted exact values" $ do
            result <- admissionSummary exactEnvelope IncusBackend
            result @?= Right ["limits.cpu=8", "limits.memory=16GiB", "root,size=100GiB"]
        , testCase "bare Linux reports unsupported instead of pretending to cordon storage" $ do
            result <- admissionSummary exactEnvelope BareLinuxBackend
            result
                @?= Left (UnsupportedBudgetWall BareLinuxBackend "the BareLinuxBackend backend cannot enforce a storage ceiling (BareLinuxQuotaAndImageGcUnavailable)")
        , testCase "every backend states its own answer to an inexact budget" $ do
            -- Admission names each constructor, so what a backend does with a
            -- budget that is not whole gibibytes is a decision rather than an
            -- inheritance. A wildcard is what made three of these unstated.
            -- The exact envelope every other case admits, made inexact in one
            -- dimension, so what differs between the backends is the exactness
            -- answer and nothing downstream of it.
            let inexact = ResourceEnvelope 8 "17179869185" "100GiB"
                inexactMemory backend = Left (InexactProviderQuantity backend "memory" (16 * gib + 1))
            lima <- admissionSummary inexact LimaBackend
            incus <- admissionSummary inexact IncusBackend
            wsl <- admissionSummary inexact Wsl2Backend
            colima <- admissionSummary inexact ColimaBackend
            [lima, incus, wsl, colima]
                @?= map inexactMemory [LimaBackend, IncusBackend, Wsl2Backend, ColimaBackend]
            -- A kind node is cordoned in bytes, so an inexact budget is admitted.
            node <- admissionSummary inexact DockerNodeBackend
            node
                @?= Right
                    [ "update"
                    , "--cpus"
                    , "8"
                    , "--memory"
                    , "17179869185"
                    , "--memory-swap"
                    , "34359738370"
                    , "demo"
                    ]
            -- Bare Linux has no wall to size against at all.
            bare <- admissionSummary inexact BareLinuxBackend
            bare
                @?= Left
                    (UnsupportedBudgetWall BareLinuxBackend "the BareLinuxBackend backend cannot enforce a storage ceiling (BareLinuxQuotaAndImageGcUnavailable)")
        , testGroup "Docker provider admission" dockerAdmissionCases
        , testGroup "plan-declared budget boundaries" planBudgetCases
        , testCase "one gate has one commitment, and a separator cannot forge it" $ do
            -- Two backends projected the same six gate fields and hashed them
            -- differently. They now commit through the one projection, so the
            -- same gate cannot produce two answers.
            gate <- gateForValues "plan-digest" "operation-key" "session-1" 3 4
            preparedGateCommitment gate @?= "69bbf1543977ef1da74c46cd215fdc3f24ef7b7bd0bf5af8280e924a51b26c6b"
            -- The construction is length-framed rather than separator-joined:
            -- these two gates are identical once the fields are run together
            -- with a colon between them, and must still commit differently.
            left <- gateForValues "plan:digest" "operation" "session-1" 3 4
            right <- gateForValues "plan" "digest:operation" "session-1" 3 4
            assertBool
                "a separator moved between two fields produced the same commitment"
                (preparedGateCommitment left /= preparedGateCommitment right)
        , testCase "prepared gate commitments preserve non-ASCII bytes" $ do
            left <- gateForValues "\x4e00" "operation-key" "session-1" 3 4
            right <- gateForValues "\x4f00" "operation-key" "session-1" 3 4
            assertBool "distinct UTF-8 plan digests must not collide" (preparedGateCommitment left /= preparedGateCommitment right)
        , testCase "workload set must be non-empty" $ do
            result <-
                withBudgetProjectPlan $ \plan _providerResource _clusterResource ->
                    pure $
                        withValidatedBudget
                            plan
                            (\_ -> withPlannedWorkloadSet plan [] (const ()))
            result @?= Right (Left EmptyWorkloadSet)
        , testCase "workload fit and constructive partition share the admitted budget" $ do
            result <- successfulPartition
            result @?= Right [("core:deploy-vm", "host", (6, 10 * gib, 80 * gib))]
        , testCase "workload and partition identities are deterministic and substitution-sensitive" $ do
            first <- workloadPartitionIdentitySummary 1 6
            repeated <- workloadPartitionIdentitySummary 1 6
            workloadChanged <- workloadPartitionIdentitySummary 2 6
            partitionChanged <- workloadPartitionIdentitySummary 1 5
            first @?= repeated
            assertBool "replica drift retained the workload/partition digest" (first /= workloadChanged)
            assertBool "slice-budget drift retained the workload/partition digest" (first /= partitionChanged)
        , testCase "workload identity retains exact authoring order without delimiter ambiguity" $ do
            forwardIdentity <- workloadOrderIdentitySummary False
            reversedIdentity <- workloadOrderIdentitySummary True
            assertBool "reordered workloads retained one canonical digest" (forwardIdentity /= reversedIdentity)
        , testCase "the stable chart declaration matches only its exact generative workload partition" $ do
            exact <- chartBindingSummary "1e046bfc5e54f83b6e493f9d2222217011a4d58e477c31c65b6c351515b9e3a8"
            drifted <- chartBindingSummary "sha256:another-partition"
            exact @?= Right ("sha256:chart", "demo", "demo-system", "sha256:values", "image@sha256:digest", "api", ["deployment:demo"])
            case drifted of
                Left reason -> assertBool "the mismatch did not identify partition drift" ("chart declaration digest differs" `Text.isInfixOf` reason)
                Right _ -> assertFailure "a substituted chart declaration digest matched"
        , testCase "workload and slice identity are projected from the admitted plan" $ do
            result <- projectedIdentitySummary
            case result of
                Right (workloadIdentity, projectedWorkloadIdentity, sliceIdentities, projectedSliceIdentity) -> do
                    workloadIdentity @?= projectedWorkloadIdentity
                    sliceIdentities @?= [projectedSliceIdentity]
                other -> assertFailure ("expected projected workload and slice identities, got " ++ show other)
        , testCase "an action-local slice retains the exact planned resource and closed budget" $ do
            budget <- either (assertFailure . show) pure (mkResourceBudget 3 (4 * gib) (20 * gib))
            result <-
                withBudgetProjectPlan $ \_plan _provider cluster ->
                    pure $
                        withActionResourceSlice cluster budget $ \slice ->
                            (resourceSliceName slice, resourceSliceFrame slice, budgetCpu (resourceSliceBudget slice))
            result @?= ("core:deploy-kind", "provider", 3)
        , testCase "partition rejects slices plus overhead above effective budget" $ do
            result <- overflowingPartition
            result @?= Left (PartitionOverflow "cpu" 9 8)
        , privateWallSettlementCases
        , testCase "provider-wall observations have one private descriptive declaration home" $
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                let readSource path = Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile path
                    moduleName = "HostBootstrap.Cluster.Budget.Observation"
                description <- readSource (packageRoot </> "hostbootstrap-core.cabal")
                kernel <- readSource (packageRoot </> "src" </> "HostBootstrap" </> "Cluster" </> "Budget" </> "Internal.hs")
                vocabulary <- readSource (packageRoot </> "internal" </> "wall-observation" </> "HostBootstrap" </> "Cluster" </> "Budget" </> "Observation.hs")
                public <- either assertFailure pure (SourceGuard.effectiveMainExposedModules description)
                assertBool "the declaration owner is private" (moduleName `notElem` public)
                private <- maybe (assertFailure "the observation leaf is absent") pure
                    (SourceGuard.namedStanza "library wall-observation-internal" description)
                SourceGuard.fieldValues "visibility" private @?= ["private"]
                SourceGuard.fieldValues "hs-source-dirs" private @?= ["internal/wall-observation"]
                SourceGuard.fieldModules "exposed-modules" private @?= [moduleName]
                SourceGuard.fieldValues "build-depends" private
                    @?= ["base", ">=4.18", "&&", "<5", "hostbootstrap-core:reconcile-error-internal"]
                expected <- maybe (assertFailure "the observation export pin is absent") pure
                    (lookup moduleName pinnedPrivateExportLists)
                SourceGuard.moduleExportTokens moduleName vocabulary @?= Just (SourceGuard.haskellTokens expected)
                SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "data WallAcquireObservation") kernel @?= 0
                SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "data WallAcquireObservation") vocabulary @?= 1
                assertBool "the existing kernel imports and reexports the same descriptive type"
                    (SourceGuard.importsModule moduleName kernel)
                kernelExports <- maybe (assertFailure "the budget kernel export list is absent") pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Cluster.Budget.Internal" kernel)
                assertBool "the observation remains available through the budget kernel"
                    ("WallAcquireObservation" `elem` kernelExports)
        , testCase "only the budget facade and owning Colima adapter import the private kernel" budgetKernelImportCase
        , testCase "the exact journal gate mints the provider reservation fence" $ do
            result <- reservationGateSummary ExactReservationGate
            result @?= Right 7
        , testCase "a reservation cannot size another provider operation sharing its fence" $ do
            result <- crossProviderReservationSummary
            result @?= Right (Right 7, Left (InvalidProviderPackage "the reservation was journaled for another provider operation"))
        , testCase "a gate from another plan cannot reserve the provider wall" $ do
            result <- reservationGateSummary WrongReservationPlan
            result @?= Left (InvalidWallReservation "the prepare gate belongs to another project plan")
        , testCase "a gate for another operation cannot reserve the provider wall" $ do
            result <- reservationGateSummary WrongReservationOperation
            result @?= Left (InvalidWallReservation "the prepare gate belongs to another provider operation")
        , testCase "a zero journal fence cannot reserve the provider wall" $ do
            result <- reservationGateSummary ZeroReservationFence
            result @?= Left (InvalidWallReservation "the prepare gate fence must be positive")
        , testCase "prepared storage mechanisms equal the canonical provider policy" $
            forM_
                [ (ColimaBackend, ColimaVmStorage)
                , (LimaBackend, LimaVmStorage)
                , (IncusBackend, IncusVmStorage)
                , (Wsl2Backend, Wsl2DistroStorage)
                ] $ \(backend, target) -> do
                    result <- storageWallSummary backend (Right . storageWallCallMechanism)
                    case result of
                        Right (Right mechanism) -> StorageCordonSupported mechanism @?= storageCordonPolicy target
                        other -> assertFailure ("expected a prepared storage wall, got " <> show other)
        , testCase "the storage-wall call renders each provider launch token" $ do
            lima <- storageWallSummary LimaBackend storageWallShape
            lima @?= Right (Right (LimaDiskFlag, ["--disk", "100"], 100 * gib))
            colima <- storageWallSummary ColimaBackend storageWallShape
            colima
                @?= Right
                    ( Right
                        ( ColimaDiskFlag
                        ,
                            [ "start"
                            , "--profile"
                            , "demo"
                            , "--runtime"
                            , "docker"
                            , "--activate=false"
                            , "--template=false"
                            , "--ssh-config=false"
                            , "--mount"
                            , "none"
                            , "--kubernetes=false"
                            , "--network-address=false"
                            , "--mount-inotify=false"
                            , "--cpus"
                            , "8"
                            , "--memory"
                            , "16"
                            , "--root-disk"
                            , "20"
                            , "--disk"
                            , "80"
                            ]
                        , 100 * gib
                        )
                    )
            incus <- storageWallSummary IncusBackend storageWallShape
            incus
                @?= Right
                    (Right (IncusRootDiskLimit, ["-d", "root,size=100GiB"], 100 * gib))
            wsl <- storageWallSummary Wsl2Backend storageWallShape
            wsl
                @?= Right
                    (Right (Wsl2VhdSize, ["--vhd-size", "100GB"], 100 * gib))
            budget <- either (assertFailure . show) pure (mkResourceBudget 8 (16 * gib) (100 * gib))
            limaLaunch <- either assertFailure pure (BudgetRenderer.limaSizingArgsForBudget budget)
            incusLaunch <- either assertFailure pure (BudgetRenderer.incusSizingArgsForBudget budget)
            wslVhd <- either assertFailure pure (BudgetRenderer.wsl2VhdSizeArgForBudget budget)
            lima @?= Right (Right (LimaDiskFlag, drop 4 limaLaunch, 100 * gib))
            incus @?= Right (Right (IncusRootDiskLimit, "-d" : drop 2 incusLaunch, 100 * gib))
            wsl @?= Right (Right (Wsl2VhdSize, ["--vhd-size", wslVhd], 100 * gib))
        , testCase "a kind node container is Unsupported, never a silent success" $ do
            result <- storageWallSummary DockerNodeBackend storageWallShape
            case storageCordonPolicy DockerNodeStorage of
                StorageCordonUnsupported reason ->
                    result
                        @?= Right
                            ( Left
                                ( Unsupported
                                    ( UnsupportedDetail
                                        "apply storage wall"
                                        ("the DockerNodeBackend backend cannot enforce a storage ceiling (" <> Text.pack (show reason) <> ")")
                                    )
                                )
                            )
                other -> assertFailure ("expected an unsupported storage policy, got " <> show other)
        , testCase "bare Linux is refused before a storage wall is even prepared" $ do
            -- Admission refuses this provider before a prepared wall can exist.
            -- Its public refusal still carries the canonical storage reason.
            result <- storageWallSummary BareLinuxBackend storageWallShape
            case storageCordonPolicy BareLinuxStorage of
                StorageCordonUnsupported reason ->
                    result
                        @?= Left
                            ( UnsupportedBudgetWall
                                BareLinuxBackend
                                ("the BareLinuxBackend backend cannot enforce a storage ceiling (" <> show reason <> ")")
                            )
                other -> assertFailure ("expected an unsupported storage policy, got " <> show other)
        , testCase "storage policy has one declaration vocabulary across all libraries" $
            -- DEVELOPMENT_PLAN/rationale.md: "Storage ceilings have one policy".
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                description <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                sources <- SourceGuard.readLibrarySources packageRoot description
                forM_ sources $ \(name, path, source) ->
                    forM_ ["StorageWallMechanism", "StorageWallUnsupported"] $ \identifier ->
                        assertBool
                            (identifier <> " is defined or used by " <> name <> " at " <> SourceGuard.repoRelativePath packageRoot path)
                            (SourceGuard.countHaskellIdentifier identifier source == 0)
        , testCase "an inexact declared ceiling never reaches the storage wall" $ do
            result <-
                storageWallSummaryFor
                    (ResourceEnvelope 8 "16GiB" (Text.pack (show (100 * gib + 1))))
                    LimaBackend
                    storageWallShape
            assertBool
                "admission refuses an inexact storage quantity before any wall call"
                (isLeft result)
        ]

-- | The prepared storage wall's mechanism, argv, and exact declared ceiling.
storageWallShape ::
    PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
    Either ReconcileError (StorageCordonMechanism, [String], Integer)
storageWallShape prepared =
    Right
        ( storageWallCallMechanism prepared
        , storageWallCallArgs prepared
        , storageWallCeilingBytes prepared
        )

dockerAdmissionCases :: [TestTree]
dockerAdmissionCases =
    [ admissionCase "ordinary byte-granular values remain exact at admission" 8 17179869185 $
        Right (8, 17179869185, 20 * gib)
    , admissionCase "the largest whole NanoCPUs value is admitted" 9223372036 6291456 $
        Right (9223372036, 6291456, 20 * gib)
    , admissionCase "CPU overflow is refused at admission" 9223372037 6291456 $
        Left (InvalidBudget "Docker CPU budget 9223372037 cores exceeds the signed 64-bit NanoCPUs limit of 9223372036 whole cores")
    , admissionCase "the daemon minimum memory is admitted without a workload floor" 4 6291456 $
        Right (4, 6291456, 20 * gib)
    , admissionCase "sub-minimum memory is refused at admission" 4 6291455 $
        Left (InvalidBudget "Docker memory budget 6291455 bytes is below the Linux daemon minimum of 6291456 bytes")
    , admissionCase "the largest CLI-exact memory below the swap bound is admitted" 4 4611686018427387392 $
        Right (4, 4611686018427387392, 20 * gib)
    , admissionCase "the raw half-Int64 memory bound is refused for precision loss at admission" 4 4611686018427387903 $
        Left (InvalidBudget "Docker memory budget 4611686018427387903 bytes is not exactly representable by the Docker CLI binary64 byte parser")
    , admissionCase "doubled memory overflow is refused at admission" 4 4611686018427387904 $
        Left (InvalidBudget "Docker memory budget 4611686018427387904 bytes doubles to 9223372036854775808 bytes, exceeding the signed 64-bit --memory-swap limit of 9223372036854775807 bytes")
    , admissionCase "two-to-the-53 plus one is refused for precision loss at admission" 4 9007199254740993 $
        Left (InvalidBudget "Docker memory budget 9007199254740993 bytes is not exactly representable by the Docker CLI binary64 byte parser")
    , admissionCase "two-to-the-53 plus two retains its exact admitted value" 4 9007199254740994 $
        Right (4, 9007199254740994, 20 * gib)
    ]
  where
    admissionCase :: String -> Natural -> Integer -> Either BudgetError (Natural, Integer, Integer) -> TestTree
    admissionCase label cores memoryBytes expected =
        testCase label $ do
            result <-
                providerAdmissionSummary
                    (ResourceEnvelope cores (Text.pack (show memoryBytes)) "20GiB")
                    DockerNodeBackend
            result @?= expected

planBudgetCases :: [TestTree]
planBudgetCases =
    [ testCase "repeated admission reads the one budget retained by the same plan" $
        Fixture.withFixtureProjectPlanConfig (declareEnvelope exactEnvelope) budgetPlan $ \plan config -> do
            budgetResourceEnvelope config @?= exactEnvelope
            expected <- either (assertFailure . show) pure (mkResourceBudget 8 (16 * gib) (100 * gib))
            let first = withValidatedBudget plan validatedBudgetValue
                second = withValidatedBudget plan validatedBudgetValue
            (first, second) @?= (Right expected, Right expected)
    , testCase "replicas make workload CPU exceed the effective budget" $
        workloadFitSummary 9 1 gib gib >>= (@?= Left (WorkloadOverflow "cpu" 9 8))
    , testCase "replicas make workload memory exceed the effective budget" $
        workloadFitSummary 2 1 (9 * gib) gib >>= (@?= Left (WorkloadOverflow "memory" (18 * gib) (16 * gib)))
    , testCase "replicas make workload storage exceed the effective budget" $
        workloadFitSummary 2 1 gib (51 * gib) >>= (@?= Left (WorkloadOverflow "storage" (102 * gib) (100 * gib)))
    , testCase "a cluster workload refuses zero replicas exactly" $
        invalidWorkloadSummary 0 1 gib gib >>= (@?= Left (InvalidWorkload "core:deploy-kind: replicas must be positive"))
    , testCase "a cluster workload refuses zero CPU exactly" $
        invalidWorkloadSummary 1 0 gib gib >>= (@?= Left (InvalidWorkload "core:deploy-kind: CPU must be positive"))
    , testCase "a cluster workload refuses zero memory exactly" $
        invalidWorkloadSummary 1 1 0 gib >>= (@?= Left (InvalidWorkload "core:deploy-kind: memory must be positive"))
    , testCase "a cluster workload refuses zero storage exactly" $
        invalidWorkloadSummary 1 1 gib 0 >>= (@?= Left (InvalidWorkload "core:deploy-kind: storage must be positive"))
    , testCase "a provider package refuses another admitted plan's genuine topology" $
        providerPackageSummary
            >>= ( @?= Right
                    ( Right ()
                    , Left (InvalidProviderPackage "the supplied topology is not the exact topology projected by the project plan")
                    )
                )
    , testCase "partition memory includes overhead without overflowing earlier dimensions" $
        partitionBoundarySummary (1, gib, gib) (6, 16 * gib, 80 * gib)
            >>= (@?= Left (PartitionOverflow "memory" (17 * gib) (16 * gib)))
    , testCase "partition storage includes overhead without overflowing earlier dimensions" $
        partitionBoundarySummary (1, gib, gib) (6, 10 * gib, 100 * gib)
            >>= (@?= Left (PartitionOverflow "storage" (101 * gib) (100 * gib)))
    , testCase "slices plus overhead may equal every effective budget dimension exactly" $
        partitionBoundarySummary (2, 6 * gib, 20 * gib) (6, 10 * gib, 80 * gib)
            >>= (@?= Right [("core:deploy-vm", "host", (6, 10 * gib, 80 * gib))])
    , testCase "a provider slice refuses only its below-minimum CPU" $
        minimumSliceSummary (1, 2 * gib, 2 * gib)
            >>= (@?= Left (InvalidSlice "core:deploy-vm: CPU is below the provider minimum"))
    , testCase "a provider slice refuses only its below-minimum memory" $
        minimumSliceSummary (2, gib, 2 * gib)
            >>= (@?= Left (InvalidSlice "core:deploy-vm: memory is below the provider minimum"))
    , testCase "a provider slice refuses only its below-minimum storage" $
        minimumSliceSummary (2, 2 * gib, gib)
            >>= (@?= Left (InvalidSlice "core:deploy-vm: storage is below the provider minimum"))
    , testCase "plan-declared zero memory retains the closed quantity refusal" $
        quantityAdmissionSummary "0" >>= (@?= Left (InvalidQuantity (DimensionNotPositive BudgetMemory)))
    , testCase "plan-declared unknown memory unit retains the full quantity refusal" $
        quantityAdmissionSummary "8Qi" >>= (@?= Left (InvalidQuantity (QuantityUnknownUnit "Qi" "8Qi")))
    ]

withEffectiveBudgetFixture ::
    ( forall projectId specDigest planId configId providerId providerFrame clusterId clusterFrame budgetId capabilityId wallSpecId.
      ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      PlannedResource (Production projectId) planId clusterId ClusterResource clusterFrame ->
      EffectiveBudget (Production projectId) planId budgetId LimaProvider capabilityId wallSpecId ->
      Either BudgetError result
    ) ->
    IO (Either BudgetError result)
withEffectiveBudgetFixture consume =
    withBudgetProjectPlan $ \plan provider cluster -> pure $
        joinBudget $ withValidatedBudget plan $ \validated ->
            withProviderBudgetCapability plan provider LimaProviderKey $ \capability ->
                joinBudget $ admitProviderBudget validated capability $ \_wall effective ->
                    consume plan provider cluster effective

workloadFitSummary :: Natural -> Natural -> Integer -> Integer -> IO (Either BudgetError ())
workloadFitSummary replicas cores memoryBytes storageBytes =
    withEffectiveBudgetFixture $ \plan _provider cluster effective -> do
        workload <- mkWorkload cluster replicas cores memoryBytes storageBytes
        joinBudget $ withPlannedWorkloadSet plan [workload] $ \workloads ->
            () <$ verifyPlannedWorkloadFit effective workloads

invalidWorkloadSummary :: Natural -> Natural -> Integer -> Integer -> IO (Either BudgetError ())
invalidWorkloadSummary replicas cores memoryBytes storageBytes =
    withBudgetProjectPlan $ \_plan _provider cluster -> pure $
        () <$ mkWorkload cluster replicas cores memoryBytes storageBytes

partitionBoundarySummary ::
    (Natural, Integer, Integer) ->
    (Natural, Integer, Integer) ->
    IO (Either BudgetError [(String, String, (Integer, Integer, Integer))])
partitionBoundarySummary (overheadCpu, overheadMemory, overheadStorage) (sliceCpu, sliceMemory, sliceStorage) =
    withEffectiveBudgetFixture $ \plan provider cluster effective -> do
        workload <- mkWorkload cluster 1 1 gib gib
        overhead <- mapBudgetError (mkResourceBudget overheadCpu overheadMemory overheadStorage)
        sliceBudget <- mapBudgetError (mkResourceBudget sliceCpu sliceMemory sliceStorage)
        minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
        request <- mkSliceRequest provider sliceBudget minimumBudget
        joinBudget $ withPlannedWorkloadSet plan [workload] $ \workloads -> do
            fit <- verifyPlannedWorkloadFit effective workloads
            withBudgetPartition effective fit overhead (request :| []) $ \_partition slices ->
                forResourceSlices slices $ \slice ->
                    let budget = resourceSliceBudget slice
                     in (resourceSliceName slice, resourceSliceFrame slice, (toInteger (budgetCpu budget), budgetMemoryBytes budget, budgetStorageBytes budget))

minimumSliceSummary :: (Natural, Integer, Integer) -> IO (Either BudgetError ())
minimumSliceSummary (cores, memoryBytes, storageBytes) =
    withBudgetProjectPlan $ \_plan provider _cluster -> pure $ do
        actual <- mapBudgetError (mkResourceBudget cores memoryBytes storageBytes)
        required <- mapBudgetError (mkResourceBudget 2 (2 * gib) (2 * gib))
        () <$ mkSliceRequest provider actual required

quantityAdmissionSummary :: Text.Text -> IO (Either BudgetError ())
quantityAdmissionSummary memoryText =
    withBudgetProjectPlanFor (ResourceEnvelope 8 memoryText "100GiB") $ \plan _provider _cluster ->
        pure (withValidatedBudget plan (const ()))

providerPackageSummary :: IO (Either BudgetError (Either BudgetError (), Either BudgetError ()))
providerPackageSummary =
    Fixture.withFixtureProjectPlanPair budgetPlan alternativePlan $ \plan otherPlan -> do
        assertBool "the genuinely admitted topologies do not differ" $
            topologyFrameOrder (topology plan) /= topologyFrameOrder (topology otherPlan)
        case NonEmpty.toList (forward plan) of
            [providerNode, clusterNode] ->
                either (assertFailure . show) id $
                    withPlannedResourceOfKind plan ProviderResourceKind (plannedStepOperationKey providerNode) $ \provider ->
                        either (assertFailure . show) id $
                            withPlannedResourceOfKind plan ClusterResourceKind (plannedStepOperationKey clusterNode) $ \cluster -> do
                                gate <- exactProviderGate plan provider
                                pure $ do
                                    workload <- mkWorkload cluster 1 1 gib gib
                                    overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
                                    sliceBudget <- mapBudgetError (mkResourceBudget 2 (4 * gib) (10 * gib))
                                    minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
                                    request <- mkSliceRequest provider sliceBudget minimumBudget
                                    joinBudget $ withValidatedBudget plan $ \validated ->
                                        withProviderBudgetCapability plan provider LimaProviderKey $ \capability ->
                                            joinBudget $ admitProviderBudget validated capability $ \wall effective ->
                                                joinBudget $ withPlannedWorkloadSet plan [workload] $ \workloads -> do
                                                    fit <- verifyPlannedWorkloadFit effective workloads
                                                    joinBudget $ withBudgetPartition effective fit overhead (request :| []) $ \partition _slices ->
                                                        withProviderWallReservation plan provider wall partition gate $ \reservation ->
                                                            let prepare supplied =
                                                                    () <$ preparePlanOwnedProviderWallCall
                                                                        plan provider supplied validated capability wall fit partition reservation "demo"
                                                             in (prepare (topology plan), prepare (alignPackageTopologyForRefusal (topology otherPlan)))
            nodes -> assertFailure ("expected provider and cluster nodes, got " ++ show (length nodes))
  where
    alternativePlan = either (error . show) id $ mkStepPlan
        [contextInitStep "another topology" (StepFrame "other-host" "Other host") (const (pure StepChanged))
        ]

-- Both gates share fence 7; only their genuine provider operations differ.
crossProviderReservationSummary :: IO (Either BudgetError (Either BudgetError Word64, Either BudgetError Word64))
crossProviderReservationSummary =
    Fixture.withFixtureProjectPlanConfig (declareEnvelope exactEnvelope) twoProviderPlan $ \plan _config ->
        case NonEmpty.toList (forward plan) of
            [firstNode, secondNode, clusterNode] ->
                either (assertFailure . show) id $
                    withPlannedResourceOfKind plan ProviderResourceKind (plannedStepOperationKey firstNode) $ \firstProvider ->
                        either (assertFailure . show) id $
                            withPlannedResourceOfKind plan ProviderResourceKind (plannedStepOperationKey secondNode) $ \secondProvider ->
                                either (assertFailure . show) id $
                                    withPlannedResourceOfKind plan ClusterResourceKind (plannedStepOperationKey clusterNode) $ \cluster -> do
                                        let planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
                                        assertBool "the fixture must contain two distinct provider operations" (plannedResourceKey firstProvider /= plannedResourceKey secondProvider)
                                        firstGate <- gateForValues planDigest (plannedResourceKey firstProvider) "session-1" 7 3
                                        secondGate <- gateForValues planDigest (plannedResourceKey secondProvider) "session-1" 7 3
                                        pure $ do
                                            workload <- mkWorkload cluster 1 1 gib gib
                                            overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
                                            sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
                                            minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
                                            request <- mkSliceRequest secondProvider sliceBudget minimumBudget
                                            joinBudget $ withValidatedBudget plan $ \validated ->
                                                withProviderBudgetCapability plan secondProvider LimaProviderKey $ \capability ->
                                                    joinBudget $ admitProviderBudget validated capability $ \wall effective ->
                                                        joinBudget $ withPlannedWorkloadSet plan [workload] $ \workloads -> do
                                                            fit <- verifyPlannedWorkloadFit effective workloads
                                                            joinBudget $ withBudgetPartition effective fit overhead (request :| []) $ \partition _slices -> do
                                                                let prepare reservation =
                                                                        providerWallCallFence
                                                                            <$> preparePlanOwnedProviderWallCall
                                                                                plan secondProvider (topology plan) validated capability wall fit partition reservation "demo"
                                                                matched <- withProviderWallReservation plan secondProvider wall partition secondGate prepare
                                                                crossed <- withProviderWallReservation plan firstProvider wall partition firstGate prepare
                                                                pure (matched, crossed)
            nodes -> assertFailure ("expected two providers and one cluster, got " <> show (length nodes))
  where
    twoProviderPlan = either (error . show) id $ mkStepPlan
        [ declaresProviderResource providerResourceAtCurrentFrame $
            projectStep (either error id (projectStepId "first-provider")) ProjectManagedReverse "first provider" (StepFrame "host" "Host") (const (pure StepChanged))
        , descendsVia localContext $
            deployVMStep "second provider" (StepFrame "host" "Host") (const (pure StepChanged))
        , deployKindStep "cluster" (StepFrame "provider" "Provider") (const (pure StepChanged))
        ]

-- A negative-only alignment preserves the actual alternate topology and scope.
alignPackageTopologyForRefusal :: DerivedTopology scope sourcePlanId -> DerivedTopology scope targetPlanId
alignPackageTopologyForRefusal = unsafeCoerce

-- Stop in admission's actual continuation: later workload, partition, reservation,
-- and wall-rendering stages cannot provide a refusal on this path.
providerAdmissionSummary ::
    ResourceEnvelope ->
    ProviderBackend ->
    IO (Either BudgetError (Natural, Integer, Integer))
providerAdmissionSummary envelope backend =
    withBudgetProjectPlanFor envelope $ \plan providerResource _clusterResource ->
        pure $
            joinBudget $
                withValidatedBudget plan $ \validated ->
                    withProviderKeyForBackend backend $ \providerKey ->
                        withProviderBudgetCapability plan providerResource providerKey $ \capability ->
                            admitProviderBudget validated capability $ \_wall effective ->
                                let budget = effectiveBudgetValue effective
                                 in (budgetCpu budget, budgetMemoryBytes budget, budgetStorageBytes budget)

storageWallSummary ::
    ProviderBackend ->
    ( forall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence.
      PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
      Either ReconcileError result
    ) ->
    IO (Either BudgetError (Either ReconcileError result))
storageWallSummary = storageWallSummaryFor exactEnvelope

{- | Prepare the storage wall from already-admitted budget inputs, so no case
can hand the wall a value admission would have refused.
-}
storageWallSummaryFor ::
    ResourceEnvelope ->
    ProviderBackend ->
    ( forall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence.
      PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
      Either ReconcileError result
    ) ->
    IO (Either BudgetError (Either ReconcileError result))
storageWallSummaryFor envelope backend consume =
    withBudgetProjectPlanFor envelope $ \plan providerResource clusterResource -> do
        gate <- exactProviderGate plan providerResource
        pure $ do
            workload <- mkWorkload clusterResource 1 1 gib gib
            overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
            sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
            minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
            request <- mkSliceRequest providerResource sliceBudget minimumBudget
            joinBudget $ withValidatedBudget plan $ \validated ->
                withProviderKeyForBackend backend $ \providerKey ->
                    withProviderBudgetCapability plan providerResource providerKey $ \capability ->
                        joinBudget $
                            admitProviderBudget validated capability $ \wall effective ->
                                joinBudget $
                                    withPlannedWorkloadSet plan [workload] $ \workloads -> do
                                        fit <- verifyPlannedWorkloadFit effective workloads
                                        joinBudget $
                                            withBudgetPartition effective fit overhead (request :| []) $ \partition _slices ->
                                                joinBudget $
                                                    withProviderWallReservation plan providerResource wall partition gate $ \reservation ->
                                                        Right
                                                            ( prepareStorageWallCall "demo" wall partition reservation
                                                                >>= consume
                                                            )

admissionSummary :: ResourceEnvelope -> ProviderBackend -> IO (Either BudgetError [String])
admissionSummary envelope backend =
    withBudgetProjectPlanFor envelope $ \plan providerResource clusterResource -> do
        gate <- exactProviderGate plan providerResource
        pure $
            joinBudget $
                withValidatedBudget plan $ \validated ->
                    withProviderKeyForBackend backend $ \providerKey ->
                        withProviderBudgetCapability plan providerResource providerKey $ \capability ->
                            joinBudget $
                                admitProviderBudget validated capability $ \wall effective -> do
                                    workload <- mkWorkload clusterResource 1 1 gib gib
                                    overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
                                    sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
                                    minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
                                    request <- mkSliceRequest providerResource sliceBudget minimumBudget
                                    joinBudget $
                                        withPlannedWorkloadSet plan [workload] $ \workloads -> do
                                            fit <- verifyPlannedWorkloadFit effective workloads
                                            joinBudget $
                                                withBudgetPartition effective fit overhead (request :| []) $ \partition _slices ->
                                                    joinBudget $
                                                        withProviderWallReservation plan providerResource wall partition gate $ \reservation ->
                                                            providerWallCallArgs
                                                                <$> prepareProviderWallCall "demo" wall partition reservation

successfulPartition :: IO (Either BudgetError [(String, String, (Integer, Integer, Integer))])
successfulPartition =
    withBudgetProjectPlan $ \plan providerResource clusterResource ->
        pure $ do
            workload <- mkWorkload clusterResource 2 1 gib gib
            overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
            vmBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
            vmMinimum <- mapBudgetError (mkResourceBudget 1 gib gib)
            request <- mkSliceRequest providerResource vmBudget vmMinimum
            joinBudget $ withValidatedBudget plan $ \validated ->
                withProviderBudgetCapability plan providerResource LimaProviderKey $ \capability -> do
                    joinBudget $
                        admitProviderBudget validated capability $ \_wall effective ->
                            joinBudget $
                                withPlannedWorkloadSet plan [workload] $ \workloads -> do
                                    fit <- verifyPlannedWorkloadFit effective workloads
                                    withBudgetPartition effective fit overhead (request :| []) $ \_partition slices ->
                                        forResourceSlices slices $ \slice ->
                                            let budget = resourceSliceBudget slice
                                             in ( resourceSliceName slice
                                                , resourceSliceFrame slice
                                                ,
                                                    ( toInteger (budgetCpu budget)
                                                    , budgetMemoryBytes budget
                                                    , budgetStorageBytes budget
                                                    )
                                                )

workloadPartitionIdentitySummary :: Natural -> Natural -> IO (Either BudgetError (Text.Text, Text.Text, Text.Text))
workloadPartitionIdentitySummary replicas sliceCpu =
    withBudgetProjectPlan $ \plan providerResource clusterResource ->
        pure $ do
            workload <- mkWorkload clusterResource replicas 1 gib gib
            overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
            sliceBudget <- mapBudgetError (mkResourceBudget sliceCpu (10 * gib) (80 * gib))
            minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
            request <- mkSliceRequest providerResource sliceBudget minimumBudget
            joinBudget $ withValidatedBudget plan $ \validated ->
                withProviderBudgetCapability plan providerResource LimaProviderKey $ \capability ->
                    joinBudget $
                        admitProviderBudget validated capability $ \_wall effective ->
                            joinBudget $
                                withPlannedWorkloadSet plan [workload] $ \workloads -> do
                                    fit <- verifyPlannedWorkloadFit effective workloads
                                    withBudgetPartition effective fit overhead (request :| []) $ \partition _ ->
                                        ( plannedWorkloadSetDeclarationKey workloads
                                        , plannedWorkloadSetDigest workloads
                                        , workloadPartitionDigest workloads partition
                                        )

workloadOrderIdentitySummary :: Bool -> IO (Either BudgetError Text.Text)
workloadOrderIdentitySummary reversed =
    withBudgetProjectPlan $ \plan _provider cluster ->
        pure $ do
            first <- mkWorkload cluster 1 1 gib gib
            second <- mkWorkload cluster 2 1 gib gib
            let ordered = if reversed then [second, first] else [first, second]
            withPlannedWorkloadSet plan ordered plannedWorkloadSetDigest

projectedIdentitySummary ::
    IO
        ( Either
            BudgetError
            ( (String, String)
            , (String, String)
            , [(String, String)]
            , (String, String)
            )
        )
projectedIdentitySummary =
    withBudgetProjectPlan $ \plan providerResource clusterResource ->
        pure $ do
            workload <- mkWorkload clusterResource 1 1 gib gib
            overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
            sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
            minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
            request <- mkSliceRequest providerResource sliceBudget minimumBudget
            joinBudget $ withValidatedBudget plan $ \validated ->
                withProviderBudgetCapability plan providerResource LimaProviderKey $ \capability ->
                    joinBudget $
                        admitProviderBudget validated capability $ \_wall effective ->
                            joinBudget $
                                withPlannedWorkloadSet plan [workload] $ \workloads -> do
                                    fit <- verifyPlannedWorkloadFit effective workloads
                                    withBudgetPartition effective fit overhead (request :| []) $ \_partition slices ->
                                        ( (workloadName workload, workloadFrame workload)
                                        ,
                                            ( Text.unpack (plannedResourceKey clusterResource)
                                            , Text.unpack (plannedResourceFrame clusterResource)
                                            )
                                        , forResourceSlices slices $ \slice ->
                                            (resourceSliceName slice, resourceSliceFrame slice)
                                        ,
                                            ( Text.unpack (plannedResourceKey providerResource)
                                            , Text.unpack (plannedResourceFrame providerResource)
                                            )
                                        )

overflowingPartition :: IO (Either BudgetError ())
overflowingPartition =
    withBudgetProjectPlan $ \plan providerResource clusterResource ->
        pure $ do
            workload <- mkWorkload clusterResource 1 1 gib gib
            overhead <- mapBudgetError (mkResourceBudget 3 gib gib)
            sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
            minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
            request <- mkSliceRequest providerResource sliceBudget minimumBudget
            joinBudget $ withValidatedBudget plan $ \validated ->
                withProviderBudgetCapability plan providerResource LimaProviderKey $ \capability -> do
                    joinBudget $
                        admitProviderBudget validated capability $ \_wall effective ->
                            joinBudget $
                                withPlannedWorkloadSet plan [workload] $ \workloads -> do
                                    fit <- verifyPlannedWorkloadFit effective workloads
                                    fmap (const ()) $
                                        withBudgetPartition effective fit overhead (request :| []) $
                                            \_ _ -> ()

data ReservationGateCase
    = ExactReservationGate
    | WrongReservationPlan
    | WrongReservationOperation
    | ZeroReservationFence

reservationGateSummary :: ReservationGateCase -> IO (Either BudgetError Word64)
reservationGateSummary gateCase =
    withBudgetProjectPlan $ \plan providerResource clusterResource -> do
        let planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
            operationKey = plannedResourceKey providerResource
        gate <- case gateCase of
            ExactReservationGate -> gateForValues planDigest operationKey "session-1" 7 3
            WrongReservationPlan -> gateFor "another-plan" operationKey
            WrongReservationOperation -> gateFor planDigest "core:another-provider"
            ZeroReservationFence -> gateForValues planDigest operationKey "session-1" 0 1
        pure $ do
            workload <- mkWorkload clusterResource 1 1 gib gib
            overhead <- mapBudgetError (mkResourceBudget 1 gib gib)
            sliceBudget <- mapBudgetError (mkResourceBudget 6 (10 * gib) (80 * gib))
            minimumBudget <- mapBudgetError (mkResourceBudget 1 gib gib)
            request <- mkSliceRequest providerResource sliceBudget minimumBudget
            joinBudget $ withValidatedBudget plan $ \validated ->
                withProviderBudgetCapability plan providerResource LimaProviderKey $ \capability ->
                    joinBudget $
                        admitProviderBudget validated capability $ \wall effective ->
                            joinBudget $
                                withPlannedWorkloadSet plan [workload] $ \workloads -> do
                                    fit <- verifyPlannedWorkloadFit effective workloads
                                    joinBudget $
                                        withBudgetPartition effective fit overhead (request :| []) $ \partition _slices ->
                                            joinBudget $
                                                withProviderWallReservation plan providerResource wall partition gate $ \reservation ->
                                                    providerWallCallFence
                                                        <$> prepareProviderWallCall "demo" wall partition reservation

exactProviderGate ::
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId providerResourceId ProviderResource providerFrame ->
    IO PreparedGate
exactProviderGate plan providerResource =
    gateFor
        (stablePlanSnapshotDigest (renderSnapshot plan))
        (plannedResourceKey providerResource)

mapBudgetError :: Either QuantityError a -> Either BudgetError a
mapBudgetError = either (Left . InvalidQuantity) Right

joinBudget :: Either BudgetError (Either BudgetError a) -> Either BudgetError a
joinBudget = either Left id

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

budgetPlan :: StepPlan
budgetPlan =
    either
        (error . show)
        id
        ( mkStepPlan
            [ descendsVia
                localContext
                (deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged)))
            , deployKindStep "cluster" (StepFrame "provider" "Provider") (const (pure StepChanged))
            ]
        )

chartBudgetPlan :: Text.Text -> StepPlan
chartBudgetPlan digest =
    either
        (error . show)
        id
        ( mkStepPlan
            [ descendsVia
                localContext
                (deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged)))
            , deployKindStep "cluster" (StepFrame "provider" "Provider") (const (pure StepChanged))
            , declaresChartWorkloadResource
                "sha256:chart"
                "demo"
                "demo-system"
                "sha256:values"
                "image@sha256:digest"
                "workload-set:743653e5cbea58631accf95218253ec81fa73f5111d68e219c09791116d4b395"
                digest
                "service"
                "api"
                ["deployment:demo"]
                (deployChartStep "chart" (StepFrame "provider" "Provider") (const (pure StepChanged)))
            ]
        )

chartBindingSummary :: Text.Text -> IO (Either Text.Text (Text.Text, Text.Text, Text.Text, Text.Text, Text.Text, Text.Text, [Text.Text]))
chartBindingSummary digest =
    Fixture.withFixtureProjectPlanConfig (declareEnvelope exactEnvelope) (chartBudgetPlan digest) $ \plan _config ->
        case NonEmpty.toList (forward plan) of
            [providerNode, clusterNode, chartNode] ->
                pure $
                    joinText $
                        mapLeftShow $
                            withPlannedResourceOfKind plan ProviderResourceKind (plannedStepOperationKey providerNode) $ \provider ->
                                joinText $
                                    mapLeftShow $
                                        withPlannedResourceOfKind plan ClusterResourceKind (plannedStepOperationKey clusterNode) $ \cluster ->
                                            joinText $
                                                mapLeftShow $
                                                    withChartWorkloadResource plan (plannedStepOperationKey chartNode) $ \chart -> do
                                                        workload <- mapLeftShow (mkWorkload cluster 1 1 gib gib)
                                                        overhead <- mapLeftShow (mkResourceBudget 1 gib gib)
                                                        sliceBudget <- mapLeftShow (mkResourceBudget 6 (10 * gib) (80 * gib))
                                                        minimumBudget <- mapLeftShow (mkResourceBudget 1 gib gib)
                                                        request <- mapLeftShow (mkSliceRequest provider sliceBudget minimumBudget)
                                                        joinText $
                                                            mapLeftShow $
                                                                withValidatedBudget plan $ \validated ->
                                                                    joinText $
                                                                        mapLeftShow $
                                                                            withProviderBudgetCapability plan provider LimaProviderKey $ \capability ->
                                                                                joinText $
                                                                                    mapLeftShow $
                                                                                        admitProviderBudget validated capability $ \_wall effective ->
                                                                                            joinText $
                                                                                                mapLeftShow $
                                                                                                    withPlannedWorkloadSet plan [workload] $ \workloads -> do
                                                                                                        fit <- mapLeftShow (verifyPlannedWorkloadFit effective workloads)
                                                                                                        joinText $
                                                                                                            mapLeftShow $
                                                                                                                withBudgetPartition effective fit overhead (request :| []) $ \partition _ ->
                                                                                                                    withMatchingChartWorkloadDeclaration chart cluster workloads partition $ \artifact release namespace values image _key role effects _planDigest ->
                                                                                                                        pure (artifact, release, namespace, values, image, role, effects)
            _ -> pure (Left "chart binding fixture has the wrong node count")

mapLeftShow :: (Show failure) => Either failure value -> Either Text.Text value
mapLeftShow = either (Left . Text.pack . show) Right

joinText :: Either Text.Text (Either Text.Text value) -> Either Text.Text value
joinText = either Left id

withBudgetProjectPlan ::
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
withBudgetProjectPlan consume =
    withBudgetProjectPlanFor exactEnvelope consume

withBudgetProjectPlanFor ::
    ResourceEnvelope ->
    ( forall projectId specDigest planId configId providerId providerFrame clusterId clusterFrame.
      ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
      PlannedResource (Production projectId) planId clusterId ClusterResource clusterFrame ->
      IO result
    ) ->
    IO result
withBudgetProjectPlanFor envelope consume =
    Fixture.withFixtureProjectPlanConfig (declareEnvelope envelope) budgetPlan $ \plan _config ->
        case NonEmpty.toList (forward plan) of
            [providerNode, clusterNode] ->
                case withPlannedResourceOfKind
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

declareEnvelope :: ResourceEnvelope -> Fixture.ProjectConfig scope -> Fixture.ProjectConfig scope
declareEnvelope (ResourceEnvelope cores memoryBytes storageBytes) config =
    config{Fixture.resources = Fixture.Resources cores memoryBytes storageBytes}
