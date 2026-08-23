{-# LANGUAGE OverloadedStrings #-}

module ClusterConfigSpec (tests) where

import CommandsSpec (hostCfg)
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Either (isLeft)
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Lifecycle (ClusterDriver (KindDriver, NvkindDriver))
import HostBootstrap.Handoff (childConfigDigest)
import HostBootstrapDemo.ClusterConfig (renderExactClusterConfig, verifyExactClusterConfig)
import HostBootstrapDemo.Config (renderProjectConfig)
import Numeric.Natural (Natural)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "ClusterConfigSpec"
        [ testCase "Kind and nvkind render canonical loopback-only topology" $ do
            kind@(kindBytes, kindDigest, kindState, kindPath, kindPorts) <- expectRight (renderExactClusterConfig KindDriver digest hostCfg [(digest, "vm-project-container-2")] kindPublished)
            nvkind@(nvBytes, nvDigest, nvState, nvPath, nvPorts) <- expectRight (renderExactClusterConfig NvkindDriver digest hostCfg [(digest, "vm-project-container-1")] nvkindPublished)
            kindDigest @?= childConfigDigest kindBytes
            nvDigest @?= childConfigDigest nvBytes
            assertBool "Kind contains a wildcard publication" (not ("0.0.0.0" `ByteStringChar8.isInfixOf` kindBytes))
            assertBool "nvkind contains a wildcard publication" (not ("0.0.0.0" `ByteStringChar8.isInfixOf` nvBytes))
            kindBytes @?= kindGolden
            nvBytes @?= nvkindGolden
            assertBool "Kind gained an nvkind worker" (not ("nvidia.com/gpu.present" `ByteStringChar8.isInfixOf` kindBytes))
            assertBool "nvkind lost its GPU worker" ("nvidia.com/gpu.present" `ByteStringChar8.isInfixOf` nvBytes)
            kindState @?= "/workspace/demo/.data/cluster/kind/state"
            kindPath @?= "/workspace/demo/.data/cluster/kind/config.yaml"
            nvState @?= "/workspace/demo/.data/cluster/nvkind/state"
            nvPath @?= "/workspace/demo/.data/cluster/nvkind/config.yaml"
            kindPorts @?= kindPublished
            nvPorts @?= nvkindPublished
            verifyExactClusterConfig KindDriver digest hostCfg [(digest, "vm-project-container-2")] kindPublished kindBytes @?= Right ()
            assertBool "changed canonical bytes were accepted" (isLeft (verifyExactClusterConfig KindDriver digest hostCfg [(digest, "vm-project-container-2")] kindPublished (kindBytes <> "unknown: true\n")))
            kind `seq` nvkind `seq` pure ()
        , testCase "digest, slice, ports, bounds, and paths fail closed" $ do
            assertBool "a changed config digest was accepted" (isLeft (renderExactClusterConfig KindDriver "changed" hostCfg [(digest, "vm-project-container-2")] kindPublished))
            assertBool "an empty cluster slice was accepted" (isLeft (renderExactClusterConfig KindDriver digest hostCfg [] kindPublished))
            assertBool "a duplicate cluster slice was accepted" (isLeft (renderExactClusterConfig KindDriver digest hostCfg [(digest, "a"), (digest, "b")] kindPublished))
            assertBool "a cluster slice with a different digest was accepted" (isLeft (renderExactClusterConfig KindDriver digest hostCfg [("changed", "a")] kindPublished))
            assertBool "a duplicate port was accepted" (isLeft (renderExactClusterConfig KindDriver digest hostCfg [(digest, "a")] (("other", 30500) : kindPublished)))
            assertBool "an undeclared port was accepted" (isLeft (renderExactClusterConfig KindDriver digest hostCfg [(digest, "a")] (("other", 32000) : kindPublished)))
            assertBool "an out-of-range port was accepted" (isLeft (renderExactClusterConfig KindDriver digest hostCfg [(digest, "a")] (("web", 0) : drop 1 kindPublished)))
        ]
  where
    digest = childConfigDigest (TextEncoding.encodeUtf8 (renderProjectConfig hostCfg <> "\n"))
    kindPublished = [("registry", 30500), ("web", 30080), ("accelerator", 30081), ("minio", 30900)]
    nvkindPublished = [("registry", 30500), ("web", 30080), ("minio", 30900)]
    kindGolden =
        ByteStringChar8.pack . unlines $
            [ "kind: Cluster"
            , "apiVersion: kind.x-k8s.io/v1alpha4"
            , "nodes:"
            , "  - role: control-plane"
            , "    extraPortMappings:"
            ]
                ++ portGolden [30500, 30080, 30081, 30900]
                ++ durableGolden
    nvkindGolden =
        ByteStringChar8.pack . unlines $
            [ "kind: Cluster"
            , "apiVersion: kind.x-k8s.io/v1alpha4"
            , "nodes:"
            , "  - role: control-plane"
            , "    extraPortMappings:"
            ]
                ++ portGolden [30500, 30080, 30900]
                ++ durableGolden
                ++ [ "  - role: worker"
                   , "    labels:"
                   , "      nvidia.com/gpu.present: \"true\""
                   , "    extraMounts:"
                   , "      - hostPath: /dev/null"
                   , "        containerPath: /var/run/nvidia-container-devices/all"
                   , "      - hostPath: /workspace/demo/.data"
                   , "        containerPath: /var/lib/hostbootstrap-demo-data"
                   ]
    portGolden :: [Natural] -> [String]
    portGolden = concatMap (\port -> ["      - containerPort: " ++ show port, "        hostPort: " ++ show port, "        listenAddress: \"127.0.0.1\"", "        protocol: TCP"])
    durableGolden =
        [ "    extraMounts:"
        , "      - hostPath: /workspace/demo/.data"
        , "        containerPath: /var/lib/hostbootstrap-demo-data"
        ]

expectRight :: Either String a -> IO a
expectRight = either assertFailure pure
