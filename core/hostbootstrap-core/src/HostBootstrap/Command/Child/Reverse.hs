{-# LANGUAGE OverloadedStrings #-}

module HostBootstrap.Command.Child.Reverse (
    recoveryProfileName,
    reverseDescentBody,
    reverseObservation,
    runCoreManagedReverse,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Backend (releaseRecordedClusterExposureFenced, releaseRetainedClusterFenced)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Handoff (HandoffBinding, handoffErrorMessage, handoffScope, takeHandoffFrame)
import HostBootstrap.Handoff.Rooted (RootedReverseObservation (..), RootedReverseResource (..), renderRootedReverseObservationKernel)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Prepared (PreparedGate, preparedGateFence, preparedGateOperation, preparedGatePlan)
import HostBootstrap.Lifecycle.Execution.Internal (ExecutionNode (..))
import HostBootstrap.Lifecycle.ResourceRecord (renderRecoveredResourceReleaseKernel)
import HostBootstrap.ProjectPlan (ProjectPlan, projectPlanProjectName, renderSnapshot, stablePlanSnapshotDigest, stablePlanSnapshotRoot)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot, canonicalProjectRootPath)
import HostBootstrap.Command.Child.Reverse.Internal (coreManagedReverseKernel, recoveryProfileNameKernel)
import HostBootstrap.Step (TeardownOutcome (TeardownRefused, TeardownReleased))
import HostBootstrap.Teardown (LocalWork, localWorkAction, localWorkKey, localWorkPolicy, teardownErrorMessage, teardownObservationsFromWire)

reverseDescentBody :: ByteString -> Either Text (Text, ByteString)
reverseDescentBody body = do
    (childBytes, afterChild) <- either (Left . Text.pack . handoffErrorMessage) Right (takeHandoffFrame body)
    (observations, trailing) <- either (Left . Text.pack . handoffErrorMessage) Right (takeHandoffFrame afterChild)
    if ByteString.null trailing
        then case TextEncoding.decodeUtf8' childBytes of
            Left _ -> Left "reverse child: Descend names a non-UTF-8 child frame"
            Right child -> Right (child, observations)
        else Left "reverse child: Descend has trailing bytes"

reverseObservation :: ExecutionNode -> PreparedGate -> Maybe ByteString -> ByteString -> Either Text ByteString
reverseObservation node gate predecessor observation = do
    rows <- either (Left . Text.pack . teardownErrorMessage) Right (teardownObservationsFromWire observation)
    let operation = executionNodeOperationKey node
        frame = executionNodeFrame node
    resources <- case (rows, predecessor) of
        ([(actual, TeardownReleased)], Just previous) | actual == operation -> do
            successor <- renderRecoveredResourceReleaseKernel (preparedGatePlan gate) frame operation previous
            Right [RootedReverseResource frame operation previous successor]
        ([(actual, _)], _) | actual == operation -> Right []
        _ -> Left "reverse child: observation does not name the prepared operation"
    renderRootedReverseObservationKernel (RootedReverseObservation operation observation resources)

recoveryProfileName :: HandoffBinding scope brokerGeneration -> Either Text Text
recoveryProfileName = recoveryProfileNameKernel . handoffScope

-- | Execute the core-owned reverse action in the authenticated child frame.
runCoreManagedReverse ::
    CanonicalProjectRoot scope rootId ->
    Context.BinaryContext ->
    ProjectPlan scope specDigest planId configId cfg ->
    HostConfig ->
    PreparedGate ->
    LocalWork scope planId frame verb ->
    IO TeardownOutcome
runCoreManagedReverse root context plan host gate local
    | preparedGatePlan gate /= stablePlanSnapshotDigest (renderSnapshot plan)
        || preparedGateOperation gate /= localWorkKey local || preparedGateFence gate == 0
        || Context.project context /= projectPlanProjectName plan
        || canonicalProjectRootPath root /= stablePlanSnapshotRoot (renderSnapshot plan) =
        pure (TeardownRefused "the reverse action has no matching prepared operation fence")
    | otherwise =
        coreManagedReverseKernel
            (localWorkPolicy local)
            (localWorkAction local)
            (releaseRecordedClusterExposureFenced host plan gate)
            (releaseRetainedClusterFenced host plan gate)
