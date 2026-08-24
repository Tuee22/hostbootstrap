{-# LANGUAGE OverloadedStrings #-}

-- | Pure, canonical cluster configuration for the worked demo.
module HostBootstrapDemo.ClusterConfig (
    durableDockerHostPath,
    renderExactClusterConfig,
    verifyExactClusterConfig,
    withExactPlanOwnedClusterConfig,
) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Backend (
    ExposureIntent,
    mkExposureIntent,
 )
import HostBootstrap.Cluster.Lifecycle (
    AcceleratorDaemonPlacement (HostResidentDaemon),
    ClusterDriver (KindDriver, NvkindDriver),
    ClusterPlan (clusterName),
    PlanOwnedCluster,
    PlanOwnedClusterConfig,
    planOwnedClusterName,
    resolvePlanWithDriver,
    withPlanOwnedClusterConfig,
 )
import qualified HostBootstrap.Context as Context
import HostBootstrap.Handoff (childConfigDigest)
import HostBootstrapDemo.Config (
    ProjectConfig (context),
    acceleratorPlacementForContext,
    canonicalDemoConfigProjection,
    clusterProfileOf,
 )
import System.FilePath (isAbsolute, normalise, splitDirectories, (</>))

{- | Stable path interpreted by the Docker daemon when it creates Kind nodes.

The project container sees the same durable root at its own plan-derived path,
but that child-frame path is not meaningful to the sibling daemon.  Provider
lanes publish this alias to the exact shared root before cluster reconciliation.
-}
durableDockerHostPath :: FilePath
durableDockerHostPath = "/var/tmp/hostbootstrap-demo-data"

renderExactClusterConfig ::
    ClusterDriver ->
    Text ->
    ProjectConfig scope ->
    [(Text, Text)] ->
    Either String (ByteString, Text, FilePath, FilePath, [ExposureIntent])
renderExactClusterConfig driver retainedDigest cfg clusterSlice = do
    (_resources, _replicas, _public, _accelerator, semanticTargets, durableTarget) <-
        canonicalDemoConfigProjection retainedDigest cfg
    require (length clusterSlice == 1) "cluster slice is not singular"
    require (all ((== retainedDigest) . fst) clusterSlice) "cluster slice digest disagrees with the retained config"
    requireCanonicalPath durableTarget
    intents <- exposureIntents driver cfg semanticTargets
    let bytes = TextEncoding.encodeUtf8 (renderYaml driver)
        driverName = case driver of
            KindDriver -> "kind"
            NvkindDriver -> "nvkind"
        statePath = durableTarget </> "cluster" </> driverName </> "state"
        configPath = durableTarget </> "cluster" </> driverName </> "config.yaml"
    pure (bytes, childConfigDigest bytes, statePath, configPath, intents)

verifyExactClusterConfig ::
    ClusterDriver ->
    Text ->
    ProjectConfig scope ->
    [(Text, Text)] ->
    ByteString ->
    Either String ()
verifyExactClusterConfig driver retainedDigest cfg clusterSlice observed = do
    (canonical, _, _, _, _) <- renderExactClusterConfig driver retainedDigest cfg clusterSlice
    require (observed == canonical) "cluster config bytes are not canonical"

withExactPlanOwnedClusterConfig ::
    PlanOwnedCluster scope specDigest planId configId ProjectConfig clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
    ClusterDriver ->
    Text ->
    ProjectConfig configScope ->
    [(Text, Text)] ->
    [Text] ->
    (PlanOwnedClusterConfig scope specDigest planId configId ProjectConfig clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> result) ->
    Either String result
withExactPlanOwnedClusterConfig base driver retainedDigest cfg clusterSlice workload consume = do
    (bytes, digest, statePath, configPath, intents) <-
        renderExactClusterConfig driver retainedDigest cfg clusterSlice
    let mappings = case driver of
            KindDriver -> [("control-plane", Text.pack (planOwnedClusterName base ++ "-control-plane"))]
            NvkindDriver ->
                [ ("control-plane", Text.pack (planOwnedClusterName base ++ "-control-plane"))
                , ("worker", Text.pack (planOwnedClusterName base ++ "-worker"))
                ]
    either
        (Left . ("demo cluster config: " ++) . show)
        Right
        (withPlanOwnedClusterConfig base driver bytes digest statePath configPath intents mappings workload consume)

exposureIntents :: ClusterDriver -> ProjectConfig scope -> [(Text, Int)] -> Either String [ExposureIntent]
exposureIntents driver cfg semanticTargets = traverse makeIntent services
  where
    ctx = context cfg
    plan = resolvePlanWithDriver (Text.unpack (Context.project ctx)) (Text.unpack (Context.sourceRoot ctx)) (clusterProfileOf cfg) driver
    target = Text.pack (clusterName plan ++ "-control-plane")
    makeIntent (service, port) = either (Left . ("demo cluster config: " ++) . show) Right (mkExposureIntent service target port)
    services = case (driver, acceleratorPlacementForContext ctx) of
        (KindDriver, HostResidentDaemon) -> semanticTargets
        _ -> filter ((/= "accelerator") . fst) semanticTargets

renderYaml :: ClusterDriver -> Text
renderYaml driver =
    Text.pack . unlines $
        [ "kind: Cluster"
        , "apiVersion: kind.x-k8s.io/v1alpha4"
        , "nodes:"
        , "  - role: control-plane"
        , "    extraMounts:"
        , "      - hostPath: " ++ durableDockerHostPath
        , "        containerPath: /var/lib/hostbootstrap-demo-data"
        ]
            ++ worker
  where
    worker = case driver of
        KindDriver -> []
        NvkindDriver ->
            [ "  - role: worker"
            , "    labels:"
            , "      nvidia.com/gpu.present: \"true\""
            , "    extraMounts:"
            , "      - hostPath: /dev/null"
            , "        containerPath: /var/run/nvidia-container-devices/all"
            , "      - hostPath: " ++ durableDockerHostPath
            , "        containerPath: /var/lib/hostbootstrap-demo-data"
            ]

requireCanonicalPath :: FilePath -> Either String ()
requireCanonicalPath path = do
    require (isAbsolute path) "cluster durable target is not absolute"
    require (normalise path == path) "cluster durable target is not lexical-canonical"
    require (all (`notElem` ["..", ".", ""]) (splitDirectories path)) "cluster durable target escapes lexically"

require :: Bool -> String -> Either String ()
require True _ = Right ()
require False reason = Left ("demo cluster config: " ++ reason)
