{-# LANGUAGE OverloadedStrings #-}

module HostBootstrap.Command.Child.Reverse (
    recoveryProfileName,
    runCoreManagedReverse,
) where

import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Cluster.Backend (releaseRecordedClusterExposure, releaseRetainedCluster)
import HostBootstrap.Cluster.Lifecycle (profileFromPlanName, resolvePlan)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Handoff (HandoffBinding, handoffScope)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.ProjectPlan (ProjectPlan, projectPlanProfileName)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot, canonicalProjectRootPath)
import HostBootstrap.Step (
    ReversePolicy (CoreManagedReverse),
    TeardownAction (DeleteCluster),
    TeardownOutcome (TeardownFailed, TeardownForeignRetained, TeardownReleased),
 )
import HostBootstrap.Teardown (LocalWork, localWorkAction, localWorkPolicy)

recoveryProfileName :: HandoffBinding scope brokerGeneration -> Either Text Text
recoveryProfileName binding
    | handoffScope binding == "Production" = Right "production"
    | Just runName <- Text.stripPrefix "Harness " (handoffScope binding)
    , not (Text.null runName) =
        Right ("harness:" <> runName)
    | otherwise = Left "reverse child: the authenticated handoff carries an unknown lifecycle scope"

-- | Execute the core-owned reverse action in the authenticated child frame.
runCoreManagedReverse ::
    CanonicalProjectRoot scope rootId ->
    Context.BinaryContext ->
    ProjectPlan scope specDigest planId configId cfg ->
    HostConfig ->
    LocalWork scope planId frame verb ->
    IO TeardownOutcome
runCoreManagedReverse root context plan host local =
    case (localWorkPolicy local, localWorkAction local) of
        (CoreManagedReverse, DeleteCluster) ->
            case profileFromPlanName (projectPlanProfileName plan) of
                Left failure -> pure (TeardownFailed (show failure))
                Right profile -> do
                    let clusterPlan =
                            resolvePlan
                                (Text.unpack (Context.project context))
                                (canonicalProjectRootPath root)
                                profile
                    exposure <- releaseRecordedClusterExposure host clusterPlan
                    case exposure of
                        Left failure -> pure (TeardownFailed (show failure))
                        Right () -> do
                            released <- releaseRetainedCluster host clusterPlan
                            pure $ case released of
                                Left failure -> TeardownFailed (show failure)
                                Right () -> TeardownReleased
        (CoreManagedReverse, _) ->
            pure (TeardownForeignRetained "released with the cluster that contains it")
        _ ->
            pure (TeardownForeignRetained "the node acquired nothing this frame must release")
