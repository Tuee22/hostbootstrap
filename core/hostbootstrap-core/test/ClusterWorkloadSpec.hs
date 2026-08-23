{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}

module ClusterWorkloadSpec (tests) where

import qualified ClusterReconcileSpec
import qualified Data.ByteString.Char8 as ByteString
import qualified FakeCluster
import HostBootstrap.Cluster.Backend (runChartWorkloadCall, runChartWorkloadCleanupCall, withFreshClusterRuntimeDependency, withPreparedChartWorkload)
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import HostBootstrap.Reconcile
    ( ChangeView (..)
    , ChangedKind (..)
    , ReconcileError (..)
    , ReconcileResult
    , withReconcileResult
    )
import PrepareFixture (gateFor)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "ClusterWorkloadSpec"
        [ testCase "an exact stable declaration installs its chart" $ do
            first <- runExact Nothing
            first @?= Right (Changed Created)
            second <- runExact Nothing
            second @?= Right (Changed Created)
        , testCase "canonical values are checked before Helm is invoked" $ do
            result <- prepareRun "different\n" Nothing
            case result of
                Left (Failure _) -> pure ()
                other -> assertFailure ("expected values refusal, got " <> show other)
        , testCase "a malformed successful Helm response is refused" $ do
            result <- runArmed FakeCluster.armHelmMalformed
            case result of
                Left (Failure _) -> pure ()
                other -> assertFailure ("expected malformed-output failure, got " <> show other)
        , testCase "rollout refusal prevents a successful settlement" $ do
            result <- runArmed FakeCluster.armRolloutRefusal
            case result of
                Left (Failure _) -> pure ()
                other -> assertFailure ("expected rollout failure, got " <> show other)
        , testCase "a reported no-op without prior proof settles conservatively as repaired" $ do
            result <- runArmed FakeCluster.armHelmNoChanges
            result @?= Right (Changed Repaired)
        , testCase "cleanup removes the exact settled release and converges over absence" $ do
            result <- cleanupCase Nothing
            result @?= Right ((), ())
        , testCase "cleanup refuses an unrecognized successful uninstall" $ do
            result <- cleanupCase (Just FakeCluster.armHelmCleanupMalformed)
            case result of
                Left (Failure _) -> pure ()
                other -> assertFailure ("expected cleanup-output failure, got " <> show other)
        , testCase "successor readiness refuses a replayed nonce" $ do
            refused <- runtimeRefusal "runtime://cluster/fixture" "fixture-readiness-nonce"
            refused @?= Right ()
        , testCase "successor readiness refuses a mismatched route" $ do
            refused <- runtimeRefusal "runtime://cluster/another" "fresh-nonce"
            refused @?= Right ()
        ]

runtimeRefusal route nonce =
    ClusterReconcileSpec.withChartWorkloadFixture $ \_plan cluster _chart _workloads _partition execution _readiness _backend _root -> do
        result <- withFreshClusterRuntimeDependency execution "fixture-chart-successor" cluster "core:deploy-kind" route 1 nonce (const ())
        case result of
            Left (Failure _) -> pure (Right ())
            other -> assertFailure ("expected runtime dependency refusal, got " <> show other) >> pure (Right ())

runExact :: Maybe proof -> IO (Either ReconcileError ChangeView)
runExact _ = prepareRun "apiVersion: v1\n" Nothing

runArmed :: (FilePath -> IO ()) -> IO (Either ReconcileError ChangeView)
runArmed arm =
    prepareRun "apiVersion: v1\n" (Just arm)

prepareRun values arming =
    ClusterReconcileSpec.withChartWorkloadFixture $ \plan cluster chart _workloads _partition execution readiness _backend root -> do
        let planDigest = ProjectPlan.stablePlanSnapshotDigest (ProjectPlan.renderSnapshot plan)
        gate <- gateFor planDigest "core:deploy-chart"
        maybe (pure ()) ($ root) arming
        prepared <-
            withPreparedChartWorkload
                chart cluster readiness execution
                (ByteString.pack values) gate (runChartWorkloadCall Nothing)
        case prepared of
            Left failure -> pure (Left failure)
            Right action -> resultView <$> action

resultView :: Either ReconcileError (ReconcileResult scope planId resourceId resource phase) -> Either ReconcileError ChangeView
resultView = fmap (\result -> withReconcileResult result (\_ _ change -> change) (\_ _ -> error "chart workload unexpectedly became foreign"))

cleanupCase arming =
    ClusterReconcileSpec.withChartWorkloadFixture $ \plan cluster chart _workloads _partition execution readiness backend root -> do
        let planDigest = ProjectPlan.stablePlanSnapshotDigest (ProjectPlan.renderSnapshot plan)
        gate <- gateFor planDigest "core:deploy-chart"
        prepared <-
            withPreparedChartWorkload chart cluster readiness execution
                (ByteString.pack "apiVersion: v1\n") gate (runChartWorkloadCall Nothing)
        case prepared of
            Left failure -> pure (Left failure)
            Right runForward -> do
                forward <- runForward
                case forward of
                    Left failure -> pure (Left failure)
                    Right settlement -> do
                        maybe (pure ()) ($ root) arming
                        first <- runChartWorkloadCleanupCall backend chart settlement
                        case first of
                            Left failure -> pure (Left failure)
                            Right () -> do
                                second <- runChartWorkloadCleanupCall backend chart settlement
                                pure ((\() -> ((), ())) <$> second)
