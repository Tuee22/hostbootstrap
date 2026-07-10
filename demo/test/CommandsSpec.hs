{-# LANGUAGE OverloadedStrings #-}

module CommandsSpec (tests) where

import Data.List (isInfixOf)
import HostBootstrap.Chain (renderChain)
import HostBootstrap.Context (ContextKind (HostOrchestrator))
import HostBootstrap.Service (serviceVariantNames)
import HostBootstrap.Step (Step (..), chainFrames, frameId, postHandoffStepsForFrame, stepKindName)
import HostBootstrap.Substrate (Arch (Amd64), Substrate (Substrate), SubstrateName (LinuxCpu, LinuxGpu))
import HostBootstrapDemo.Commands (demoChainFor, demoServices)
import HostBootstrapDemo.Config (
    ProjectConfig,
    demoDefaultDeployConfig,
    demoDefaultDockerfile,
    demoDefaultMessage,
    demoDefaultResources,
    projectConfigForRole,
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "CommandsSpec"
        [ testCase "linux-gpu selects the direct host-to-container nvkind chain" $ do
            let steps = demoChainFor (Substrate LinuxGpu Amd64) hostCfg
            map frameId (chainFrames steps) @?= ["host-orchestrator-0", "vm-project-container-1"]
            map (stepKindName . stepKind) steps
                @?= [ "build-image"
                    , "context-init"
                    , "deploy-kind"
                    , "deploy-minio"
                    , "deploy-registry"
                    , "push-image"
                    , "deploy-chart"
                    , "expose-port"
                    ]
            assertBool "direct chain names nvkind" ("nvkind" `isInfixOf` renderChain steps)
        , testCase "linux-cpu keeps the VM-backed chain and post-handoff daemon hook" $ do
            let steps = demoChainFor (Substrate LinuxCpu Amd64) hostCfg
            map frameId (chainFrames steps) @?= ["host-orchestrator-0", "vm-orchestrator-1", "vm-project-container-2"]
            map stepLabel (postHandoffStepsForFrame "host-orchestrator-0" steps)
                @?= ["start the host-resident accelerator daemon after ingress is reachable"]
        , testCase "demo registers web and accelerator service variants" $
            serviceVariantNames demoServices @?= ["web", "accelerator"]
        ]

hostCfg :: ProjectConfig
hostCfg =
    projectConfigForRole
        "hostbootstrap-demo"
        "hostbootstrap-demo"
        "/workspace/demo"
        demoDefaultDockerfile
        demoDefaultResources
        demoDefaultDeployConfig
        demoDefaultMessage
        HostOrchestrator
