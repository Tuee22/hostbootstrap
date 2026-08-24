{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

module HostBootstrap.Cluster.Workload (
    PreparedChartWorkload,
    withPreparedChartWorkload,
    withPreparedActivatedChartWorkload,
    withPreparedChartWorkloadParts,
    settlePreparedChartWorkload,
    settlePreparedChartWorkloadUnchanged,
    withSettledChartWorkloadCleanup,
)
where

import qualified Crypto.Hash as Hash
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Reconcile (
    ClusterReadiness,
    clusterReadinessProbe,
    withClusterReadinessResourceHandle,
 )
import HostBootstrap.Lifecycle.Execution (StepExecution)
import HostBootstrap.Lifecycle.Plan (ChartWorkloadResource, ClusterResource, PlannedResource, withChartWorkloadResourceDetailsKernel)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Reconcile (
    BackendReconcileObservation,
    FailureDetail (..),
    Observed,
    PreparedOperation,
    PreparedPreconditions,
    PriorCommitProof,
    Provisioned,
    ReconcileError (..),
    ReconcileResult,
    RecoveryDisposition (DoNotRetry),
    ResourceHandle,
    Unclassified,
    completePreparedUnchanged,
    completeReconcile,
    plannedResourceKey,
    withPreparedChartWorkloadOperation,
    withReconcileResult,
 )

data PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion where
    PreparedChartWorkload ::
        ChartWorkloadResource scope planId chartId chartFrame ->
        ClusterReadiness scope planId clusterId clusterPhase ->
        StepExecution scope planId ->
        ByteString ->
        Maybe Text ->
        Text ->
        Text ->
        Text ->
        Text ->
        Text ->
        Text ->
        Text ->
        [Text] ->
        Text ->
        Text ->
        ResourceHandle scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) Unclassified Observed ->
        PreparedOperation scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) operationKey callDigest attempt journalVersion ->
        PreparedPreconditions scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) operationKey callDigest attempt journalVersion ->
        PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion

type role PreparedChartWorkload nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

withPreparedChartWorkload ::
    ChartWorkloadResource scope planId chartId chartFrame ->
    PlannedResource scope planId clusterId ClusterResource clusterFrame ->
    ClusterReadiness scope planId clusterId clusterPhase ->
    StepExecution scope planId ->
    ByteString ->
    PreparedGate ->
    (forall operationKey callDigest attempt journalVersion. PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion -> result) ->
    IO (Either ReconcileError result)
withPreparedChartWorkload chart cluster readiness execution valuesBytes gate consume =
    withPreparedChartWorkloadInternal chart cluster readiness execution valuesBytes Nothing gate consume

withPreparedActivatedChartWorkload ::
    ChartWorkloadResource scope planId chartId chartFrame ->
    PlannedResource scope planId clusterId ClusterResource clusterFrame ->
    ClusterReadiness scope planId clusterId clusterPhase ->
    StepExecution scope planId ->
    ByteString ->
    Text ->
    PreparedGate ->
    (forall operationKey callDigest attempt journalVersion. PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion -> result) ->
    IO (Either ReconcileError result)
withPreparedActivatedChartWorkload chart cluster readiness execution valuesBytes activationRevision gate consume
    | not (validActivationRevision activationRevision) = pure (failure "activation revision is not a canonical SHA-256 basename")
    | otherwise = withPreparedChartWorkloadInternal chart cluster readiness execution valuesBytes (Just activationRevision) gate consume
  where
    failure reason = Left (Failure (FailureDetail "prepare chart workload" reason DoNotRetry))

withPreparedChartWorkloadInternal ::
    ChartWorkloadResource scope planId chartId chartFrame ->
    PlannedResource scope planId clusterId ClusterResource clusterFrame ->
    ClusterReadiness scope planId clusterId clusterPhase ->
    StepExecution scope planId ->
    ByteString ->
    Maybe Text ->
    PreparedGate ->
    (forall operationKey callDigest attempt journalVersion. PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion -> result) ->
    IO (Either ReconcileError result)
withPreparedChartWorkloadInternal chart cluster readiness execution valuesBytes activationRevision gate consume =
    withChartWorkloadResourceDetailsKernel chart $ \artifact release namespace valuesDigest image workloadKey _workloadDigest _activationFrame role effects planDigest clusterKey ->
        let details = (artifact, release, namespace, valuesDigest, image, workloadKey, role, effects, planDigest)
         in if plannedResourceKey cluster /= clusterKey
                then pure (failure "chart declaration names another cluster resource")
                else
                    if digestText valuesBytes /= valuesDigest
                        then pure (failure "canonical values bytes differ from the admitted digest")
                        else withClusterReadinessResourceHandle readiness $ \clusterHandle ->
                            withPreparedChartWorkloadOperation
                                chart
                                clusterHandle
                                (clusterReadinessProbe readiness)
                                (callDigest details valuesBytes activationRevision)
                                gate
                                (\_dependencyKeys observed prepared preconditions -> consume (PreparedChartWorkload chart readiness execution valuesBytes activationRevision artifact release namespace valuesDigest image workloadKey role effects (plannedResourceKey cluster) (callDigest details valuesBytes activationRevision) observed prepared preconditions))
  where
    failure reason = Left (Failure (FailureDetail "prepare chart workload" reason DoNotRetry))

withPreparedChartWorkloadParts ::
    PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion ->
    ( StepExecution scope planId ->
      ByteString ->
      Maybe Text ->
      Text ->
      Text ->
      Text ->
      Text ->
      Text ->
      Text ->
      Text ->
      [Text] ->
      Text ->
      Text ->
      ResourceHandle scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) Unclassified Observed ->
      PreparedOperation scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) operationKey callDigest attempt journalVersion ->
      PreparedPreconditions scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) operationKey callDigest attempt journalVersion ->
      result
    ) ->
    result
withPreparedChartWorkloadParts (PreparedChartWorkload _ _ execution values activationRevision artifact release namespace valuesDigest image workloadKey role effects clusterKey operationCallDigest observed prepared preconditions) consume =
    consume execution values activationRevision artifact release namespace valuesDigest image workloadKey role effects clusterKey operationCallDigest observed prepared preconditions

settlePreparedChartWorkload ::
    PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion ->
    BackendReconcileObservation ->
    Either ReconcileError (ReconcileResult scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) Provisioned)
settlePreparedChartWorkload prepared observation =
    withPreparedChartWorkloadParts prepared $ \_ _ _ _ _ _ _ _ _ _ _ _ _ observed operation preconditions ->
        completeReconcile observed operation preconditions observation

settlePreparedChartWorkloadUnchanged ::
    PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion ->
    PriorCommitProof scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) ->
    Either ReconcileError (ReconcileResult scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) Provisioned)
settlePreparedChartWorkloadUnchanged prepared proof =
    withPreparedChartWorkloadParts prepared $ \_ _ _ _ _ _ _ _ _ _ _ _ _ observed operation preconditions ->
        completePreparedUnchanged observed operation preconditions proof

withSettledChartWorkloadCleanup ::
    ChartWorkloadResource scope planId chartId chartFrame ->
    ReconcileResult scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) Provisioned ->
    (Text -> Text -> result) ->
    Either ReconcileError result
withSettledChartWorkloadCleanup chart settlement consume =
    withReconcileResult
        settlement
        (\_managed _receipt _change -> Right (withDetails consume))
        (\_foreign _observation -> failure "a foreign chart release cannot be cleaned up")
  where
    withDetails use =
        withChartWorkloadResourceDetailsKernel chart $ \_artifact release namespace _values _image _workloadKey _workloadDigest _activationFrame _role _effects _planDigest _clusterKey ->
            use release namespace
    failure reason = Left (Failure (FailureDetail "prepare chart workload cleanup" reason DoNotRetry))

digestText :: ByteString -> Text
digestText bytes = "sha256:" <> Text.pack (show (Hash.hash bytes :: Hash.Digest Hash.SHA256))

callDigest :: (Text, Text, Text, Text, Text, Text, Text, [Text], Text) -> ByteString -> Maybe Text -> Text
callDigest (artifact, release, namespace, valuesDigest, image, workloadKey, role, effects, planDigest) values activationRevision =
    digestText (TextEncoding.encodeUtf8 (Text.intercalate "\NUL" (artifact : release : namespace : valuesDigest : image : workloadKey : role : planDigest : maybe "" id activationRevision : effects)) <> values)

validActivationRevision :: Text -> Bool
validActivationRevision revision =
    Text.length revision == 64
        && Text.all (\character -> character >= '0' && character <= '9' || character >= 'a' && character <= 'f') revision
