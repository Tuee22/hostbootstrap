{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

module HostBootstrap.Cluster.Workload
    ( PreparedChartWorkload
    , withPreparedChartWorkload
    , withPreparedChartWorkloadParts
    , settlePreparedChartWorkload
    , settlePreparedChartWorkloadUnchanged
    , withSettledChartWorkloadCleanup
    )
where

import qualified Crypto.Hash as Hash
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Reconcile
    ( ClusterReadiness
    , clusterReadinessProbe
    , withClusterReadinessResourceHandle
    )
import HostBootstrap.Lifecycle.Plan (ChartWorkloadResource, ClusterResource, PlannedResource, withChartWorkloadResourceDetailsKernel)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Lifecycle.Execution (StepExecution)
import HostBootstrap.Reconcile
    ( BackendReconcileObservation
    , Observed
    , PreparedOperation
    , PreparedPreconditions
    , Provisioned
    , PriorCommitProof
    , ReconcileError (..)
    , ReconcileResult
    , RecoveryDisposition (DoNotRetry)
    , ResourceHandle
    , Unclassified
    , FailureDetail (..)
    , completeReconcile
    , completePreparedUnchanged
    , plannedResourceKey
    , withPreparedChartWorkloadOperation
    , withReconcileResult
    )

data PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion where
    PreparedChartWorkload ::
        ChartWorkloadResource scope planId chartId chartFrame ->
        ClusterReadiness scope planId clusterId clusterPhase ->
        StepExecution scope planId ->
        ByteString ->
        Text -> Text -> Text -> Text -> Text -> Text -> Text -> [Text] -> Text -> Text ->
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
    withChartWorkloadResourceDetailsKernel chart $ \artifact release namespace valuesDigest image workloadKey _workloadDigest role effects planDigest clusterKey ->
        let details = (artifact, release, namespace, valuesDigest, image, workloadKey, role, effects, planDigest)
         in if plannedResourceKey cluster /= clusterKey
            then pure (failure "chart declaration names another cluster resource")
            else if digestText valuesBytes /= valuesDigest
              then pure (failure "canonical values bytes differ from the admitted digest")
              else
                withClusterReadinessResourceHandle readiness $ \clusterHandle ->
                    withPreparedChartWorkloadOperation
                        chart
                        clusterHandle
                        (clusterReadinessProbe readiness)
                        (callDigest details valuesBytes)
                        gate
                        (\_dependencyKeys observed prepared preconditions -> consume (PreparedChartWorkload chart readiness execution valuesBytes artifact release namespace valuesDigest image workloadKey role effects (plannedResourceKey cluster) (callDigest details valuesBytes) observed prepared preconditions))
  where
    failure reason = Left (Failure (FailureDetail "prepare chart workload" reason DoNotRetry))

withPreparedChartWorkloadParts ::
    PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion ->
    ( StepExecution scope planId -> ByteString -> Text -> Text -> Text -> Text -> Text -> Text -> Text -> [Text] -> Text -> Text ->
      ResourceHandle scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) Unclassified Observed ->
      PreparedOperation scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) operationKey callDigest attempt journalVersion ->
      PreparedPreconditions scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) operationKey callDigest attempt journalVersion -> result
    ) ->
    result
withPreparedChartWorkloadParts (PreparedChartWorkload _ _ execution values artifact release namespace valuesDigest image workloadKey role effects clusterKey operationCallDigest observed prepared preconditions) consume =
    consume execution values artifact release namespace valuesDigest image workloadKey role effects clusterKey operationCallDigest observed prepared preconditions

settlePreparedChartWorkload ::
    PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion ->
    BackendReconcileObservation ->
    Either ReconcileError (ReconcileResult scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) Provisioned)
settlePreparedChartWorkload prepared observation =
    withPreparedChartWorkloadParts prepared $ \_ _ _ _ _ _ _ _ _ _ _ _ observed operation preconditions ->
        completeReconcile observed operation preconditions observation

settlePreparedChartWorkloadUnchanged ::
    PreparedChartWorkload scope planId chartId chartFrame clusterId clusterPhase operationKey callDigest attempt journalVersion ->
    PriorCommitProof scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) ->
    Either ReconcileError (ReconcileResult scope planId chartId (ChartWorkloadResource scope planId chartId chartFrame) Provisioned)
settlePreparedChartWorkloadUnchanged prepared proof =
    withPreparedChartWorkloadParts prepared $ \_ _ _ _ _ _ _ _ _ _ _ _ observed operation preconditions ->
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
        withChartWorkloadResourceDetailsKernel chart $ \_artifact release namespace _values _image _workloadKey _workloadDigest _role _effects _planDigest _clusterKey ->
            use release namespace
    failure reason = Left (Failure (FailureDetail "prepare chart workload cleanup" reason DoNotRetry))

digestText :: ByteString -> Text
digestText bytes = "sha256:" <> Text.pack (show (Hash.hash bytes :: Hash.Digest Hash.SHA256))

callDigest :: (Text, Text, Text, Text, Text, Text, Text, [Text], Text) -> ByteString -> Text
callDigest (artifact, release, namespace, valuesDigest, image, workloadKey, role, effects, planDigest) values =
    digestText (TextEncoding.encodeUtf8 (Text.intercalate "\NUL" (artifact : release : namespace : valuesDigest : image : workloadKey : role : planDigest : effects)) <> values)
