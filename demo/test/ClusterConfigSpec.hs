{-# LANGUAGE OverloadedStrings #-}

module ClusterConfigSpec (tests) where

import CommandsSpec (hostCfg)
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Either (isLeft)
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Backend (
    exposureIntentService,
    exposureIntentTargetHost,
    exposureIntentTargetPort,
 )
import HostBootstrap.Cluster.Lifecycle (ClusterDriver (KindDriver, NvkindDriver))
import HostBootstrap.Handoff (childConfigDigest)
import HostBootstrapDemo.ClusterConfig (renderExactClusterConfig, verifyExactClusterConfig)
import HostBootstrapDemo.Config (renderProjectConfig)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "ClusterConfigSpec"
        [ testCase "Kind and nvkind render host-port-free topology and semantic exposure intent" $ do
            kind@(kindBytes, kindDigest, kindState, kindPath, kindIntents) <- expectRight (renderExactClusterConfig KindDriver "/var/tmp/hostbootstrap-demo-data" digest hostCfg [(digest, "vm-project-container-2")])
            nvkind@(nvBytes, nvDigest, nvState, nvPath, nvIntents) <- expectRight (renderExactClusterConfig NvkindDriver "/srv/demo/.data" digest hostCfg [(digest, "vm-project-container-1")])
            kindDigest @?= childConfigDigest kindBytes
            nvDigest @?= childConfigDigest nvBytes
            assertBool "Kind contains a wildcard publication" (not ("0.0.0.0" `ByteStringChar8.isInfixOf` kindBytes))
            assertBool "nvkind contains a wildcard publication" (not ("0.0.0.0" `ByteStringChar8.isInfixOf` nvBytes))
            assertBool "Kind rendered host publication" (not ("hostPort:" `ByteStringChar8.isInfixOf` kindBytes || "extraPortMappings:" `ByteStringChar8.isInfixOf` kindBytes))
            assertBool "nvkind rendered host publication" (not ("hostPort:" `ByteStringChar8.isInfixOf` nvBytes || "extraPortMappings:" `ByteStringChar8.isInfixOf` nvBytes))
            kindBytes @?= kindGolden
            nvBytes @?= nvkindGolden
            assertBool "Kind gained an nvkind worker" (not ("nvidia.com/gpu.present" `ByteStringChar8.isInfixOf` kindBytes))
            assertBool "nvkind lost its GPU worker" ("nvidia.com/gpu.present" `ByteStringChar8.isInfixOf` nvBytes)
            kindState @?= "/workspace/demo/.data/cluster/kind/state"
            kindPath @?= "/workspace/demo/.data/cluster/kind/config.yaml"
            nvState @?= "/workspace/demo/.data/cluster/nvkind/state"
            nvPath @?= "/workspace/demo/.data/cluster/nvkind/config.yaml"
            map intentSummary kindIntents @?= kindExpected
            map intentSummary nvIntents @?= nvkindExpected
            verifyExactClusterConfig KindDriver "/var/tmp/hostbootstrap-demo-data" digest hostCfg [(digest, "vm-project-container-2")] kindBytes @?= Right ()
            assertBool "changed canonical bytes were accepted" (isLeft (verifyExactClusterConfig KindDriver "/var/tmp/hostbootstrap-demo-data" digest hostCfg [(digest, "vm-project-container-2")] (kindBytes <> "unknown: true\n")))
            kind `seq` nvkind `seq` pure ()
        , testCase "digest, slice, and paths fail closed" $ do
            assertBool "a changed config digest was accepted" (isLeft (renderExactClusterConfig KindDriver "/var/tmp/hostbootstrap-demo-data" "changed" hostCfg [(digest, "vm-project-container-2")]))
            assertBool "an empty cluster slice was accepted" (isLeft (renderExactClusterConfig KindDriver "/var/tmp/hostbootstrap-demo-data" digest hostCfg []))
            assertBool "a duplicate cluster slice was accepted" (isLeft (renderExactClusterConfig KindDriver "/var/tmp/hostbootstrap-demo-data" digest hostCfg [(digest, "a"), (digest, "b")]))
            assertBool "a cluster slice with a different digest was accepted" (isLeft (renderExactClusterConfig KindDriver "/var/tmp/hostbootstrap-demo-data" digest hostCfg [("changed", "a")]))
            assertBool "a relative Docker-visible path was accepted" (isLeft (renderExactClusterConfig NvkindDriver "relative/.data" digest hostCfg [(digest, "vm-project-container-1")]))
        ]
  where
    digest = childConfigDigest (TextEncoding.encodeUtf8 (renderProjectConfig hostCfg <> "\n"))
    intentSummary intent = (exposureIntentService intent, exposureIntentTargetHost intent, exposureIntentTargetPort intent)
    kindExpected = [("registry", "hostbootstrap-demo-control-plane", 30500), ("web", "hostbootstrap-demo-control-plane", 30080), ("minio", "hostbootstrap-demo-control-plane", 30900), ("accelerator", "hostbootstrap-demo-control-plane", 30081)]
    nvkindExpected = [("registry", "hostbootstrap-demo-control-plane", 30500), ("web", "hostbootstrap-demo-control-plane", 30080), ("minio", "hostbootstrap-demo-control-plane", 30900)]
    kindGolden =
        ByteStringChar8.pack . unlines $
            [ "kind: Cluster"
            , "apiVersion: kind.x-k8s.io/v1alpha4"
            , "nodes:"
            , "  - role: control-plane"
            , "    extraMounts:"
            , "      - hostPath: /var/tmp/hostbootstrap-demo-data"
            , "        containerPath: /var/lib/hostbootstrap-demo-data"
            ]
    nvkindGolden =
        ByteStringChar8.pack . unlines $
            [ "kind: Cluster"
            , "apiVersion: kind.x-k8s.io/v1alpha4"
            , "nodes:"
            , "  - role: control-plane"
            , "    extraMounts:"
            , "      - hostPath: /srv/demo/.data"
            , "        containerPath: /var/lib/hostbootstrap-demo-data"
            ]
                ++ [ "  - role: worker"
                   , "    labels:"
                   , "      nvidia.com/gpu.present: \"true\""
                   , "    extraMounts:"
                   , "      - hostPath: /dev/null"
                   , "        containerPath: /var/run/nvidia-container-devices/all"
                   , "      - hostPath: /srv/demo/.data"
                   , "        containerPath: /var/lib/hostbootstrap-demo-data"
                   ]

expectRight :: Either String a -> IO a
expectRight = either assertFailure pure
