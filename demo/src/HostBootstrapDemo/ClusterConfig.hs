{-# LANGUAGE OverloadedStrings #-}

-- | Pure, canonical cluster configuration for the worked demo.
module HostBootstrapDemo.ClusterConfig (
    renderExactClusterConfig,
    verifyExactClusterConfig,
    withExactPlanOwnedClusterConfig,
) where

import Data.ByteString (ByteString)
import Data.List (nub, sortOn)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Lifecycle (
    ClusterDriver (KindDriver, NvkindDriver),
    PlanOwnedCluster,
    PlanOwnedClusterConfig,
    planOwnedClusterName,
    withPlanOwnedClusterConfig,
 )
import HostBootstrap.Handoff (childConfigDigest)
import HostBootstrapDemo.Config (ProjectConfig, canonicalDemoConfigProjection)
import Numeric.Natural (Natural)
import System.FilePath (isAbsolute, normalise, splitDirectories, (</>))

renderExactClusterConfig ::
    ClusterDriver ->
    Text ->
    ProjectConfig scope ->
    [(Text, Text)] ->
    [(Text, Natural)] ->
    Either String (ByteString, Text, FilePath, FilePath, [(Text, Natural)])
renderExactClusterConfig driver retainedDigest cfg clusterSlice published = do
    (_resources, _replicas, _public, _accelerator, durableTarget) <-
        canonicalDemoConfigProjection retainedDigest cfg
    require (length clusterSlice == 1) "cluster slice is not singular"
    require (all ((== retainedDigest) . fst) clusterSlice) "cluster slice digest disagrees with the retained config"
    requireCanonicalPath durableTarget
    ports <- canonicalPorts driver published
    let bytes = TextEncoding.encodeUtf8 (renderYaml driver durableTarget ports)
        driverName = case driver of
            KindDriver -> "kind"
            NvkindDriver -> "nvkind"
        statePath = durableTarget </> "cluster" </> driverName </> "state"
        configPath = durableTarget </> "cluster" </> driverName </> "config.yaml"
    pure (bytes, childConfigDigest bytes, statePath, configPath, ports)

verifyExactClusterConfig ::
    ClusterDriver ->
    Text ->
    ProjectConfig scope ->
    [(Text, Text)] ->
    [(Text, Natural)] ->
    ByteString ->
    Either String ()
verifyExactClusterConfig driver retainedDigest cfg clusterSlice published observed = do
    (canonical, _, _, _, _) <- renderExactClusterConfig driver retainedDigest cfg clusterSlice published
    require (observed == canonical) "cluster config bytes are not canonical"

withExactPlanOwnedClusterConfig ::
    PlanOwnedCluster scope specDigest planId configId ProjectConfig clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
    ClusterDriver ->
    Text ->
    ProjectConfig configScope ->
    [(Text, Text)] ->
    [(Text, Natural)] ->
    [Text] ->
    (PlanOwnedClusterConfig scope specDigest planId configId ProjectConfig clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> result) ->
    Either String result
withExactPlanOwnedClusterConfig base driver retainedDigest cfg clusterSlice published workload consume = do
    (bytes, digest, statePath, configPath, ports) <-
        renderExactClusterConfig driver retainedDigest cfg clusterSlice published
    let mappings = case driver of
            KindDriver -> [("control-plane", Text.pack (planOwnedClusterName base ++ "-control-plane"))]
            NvkindDriver ->
                [ ("control-plane", Text.pack (planOwnedClusterName base ++ "-control-plane"))
                , ("worker", Text.pack (planOwnedClusterName base ++ "-worker"))
                ]
    either
        (Left . ("demo cluster config: " ++) . show)
        Right
        (withPlanOwnedClusterConfig base driver bytes digest statePath configPath ports mappings workload consume)

canonicalPorts :: ClusterDriver -> [(Text, Natural)] -> Either String [(Text, Natural)]
canonicalPorts driver supplied = do
    require (length supplied == length (nub (map snd supplied))) "cluster publication contains a duplicate port"
    require (all (\(_, port) -> port >= 1 && port <= 65535) supplied) "cluster publication contains an out-of-range port"
    require (sortOn fst supplied == sortOn fst expected) "cluster publication differs from the exact declared set"
    pure expected
  where
    expected = case driver of
        KindDriver -> [("registry", 30500), ("web", 30080), ("accelerator", 30081), ("minio", 30900)]
        NvkindDriver -> [("registry", 30500), ("web", 30080), ("minio", 30900)]

renderYaml :: ClusterDriver -> FilePath -> [(Text, Natural)] -> Text
renderYaml driver durableTarget ports =
    Text.pack . unlines $
        [ "kind: Cluster"
        , "apiVersion: kind.x-k8s.io/v1alpha4"
        , "nodes:"
        , "  - role: control-plane"
        , "    extraPortMappings:"
        ]
            ++ concatMap renderPort ports
            ++ [ "    extraMounts:"
               , "      - hostPath: " ++ durableTarget
               , "        containerPath: /var/lib/hostbootstrap-demo-data"
               ]
            ++ worker
  where
    renderPort (_, port) =
        [ "      - containerPort: " ++ show port
        , "        hostPort: " ++ show port
        , "        listenAddress: \"127.0.0.1\""
        , "        protocol: TCP"
        ]
    worker = case driver of
        KindDriver -> []
        NvkindDriver ->
            [ "  - role: worker"
            , "    labels:"
            , "      nvidia.com/gpu.present: \"true\""
            , "    extraMounts:"
            , "      - hostPath: /dev/null"
            , "        containerPath: /var/run/nvidia-container-devices/all"
            , "      - hostPath: " ++ durableTarget
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
