module StepSpec (tests) where

import HostBootstrap.Step
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "StepSpec"
    [ testGroup "stepKindName" kindNameCases,
      testGroup "renderStep / renderChainPlan" renderCases,
      testGroup "frame segmentation" frameCases
    ]

-- Fixtures: frames and a representative chain interleaving host and project steps.
metal :: StepFrame
metal = StepFrame {frameId = "host-orchestrator-0", frameLabel = "metal"}

vmFrame :: StepFrame
vmFrame = StepFrame {frameId = "vm-orchestrator-1", frameLabel = "VM"}

ctrFrame :: StepFrame
ctrFrame = StepFrame {frameId = "vm-project-container-2", frameLabel = "container"}

noop :: a -> IO ()
noop _ = pure ()

-- A small demo-shaped chain: metal provisions and builds, then the container
-- frame deploys the cluster, a project step (harbor), and exposes the port.
demoChain :: [Step]
demoChain =
  [ deployVMStep "launch the VM" metal noop,
    copySourceStep "stage source into the VM" metal noop,
    ensureStep "ghc" "ensure GHC in the VM" metal noop,
    buildPbStep "build the binary in the VM" metal noop,
    contextInitStep "mint the container config" vmFrame noop,
    buildImageStep "build the project image" vmFrame noop,
    deployKindStep "bring up kind" ctrFrame noop,
    projectStep "deploy-harbor" "install harbor" ctrFrame noop,
    exposePortStep "expose the NodePort" ctrFrame noop
  ]

kindNameCases :: [TestTree]
kindNameCases =
  [ testCase "core kinds render their stable names" $
      map stepKindName coreKinds
        @?= [ "deploy-vm",
              "ensure-ghc",
              "copy-source",
              "build-pb",
              "build-image",
              "context-init",
              "deploy-kind",
              "deploy-chart",
              "expose-port"
            ],
    testCase "a project kind renders its own name (the open seam)" $
      stepKindName (ProjectStep "deploy-harbor") @?= "deploy-harbor"
  ]
  where
    coreKinds =
      [ DeployVM,
        EnsureTool "ghc",
        CopySource,
        BuildPb,
        BuildImage,
        ContextInit,
        DeployKind,
        DeployChart,
        ExposePort
      ]

renderCases :: [TestTree]
renderCases =
  [ testCase "renderStep tags the frame, the kind, and the label" $
      renderStep (deployKindStep "bring up kind" ctrFrame noop)
        @?= "[vm-project-container-2] deploy-kind — bring up kind",
    testCase "a project step renders interleaved with host steps in chain order" $
      renderChainPlan demoChain
        @?= unlines
          [ "1. [host-orchestrator-0] deploy-vm — launch the VM",
            "2. [host-orchestrator-0] copy-source — stage source into the VM",
            "3. [host-orchestrator-0] ensure-ghc — ensure GHC in the VM",
            "4. [host-orchestrator-0] build-pb — build the binary in the VM",
            "5. [vm-orchestrator-1] context-init — mint the container config",
            "6. [vm-orchestrator-1] build-image — build the project image",
            "7. [vm-project-container-2] deploy-kind — bring up kind",
            "8. [vm-project-container-2] deploy-harbor — install harbor",
            "9. [vm-project-container-2] expose-port — expose the NodePort"
          ]
  ]

frameCases :: [TestTree]
frameCases =
  [ testCase "chainFrames lists the descent frames in first-appearance order" $
      map frameId (chainFrames demoChain)
        @?= ["host-orchestrator-0", "vm-orchestrator-1", "vm-project-container-2"],
    testCase "stepsForFrame selects exactly this frame's steps in order" $
      map stepLabel (stepsForFrame "vm-project-container-2" demoChain)
        @?= ["bring up kind", "install harbor", "expose the NodePort"],
    testCase "stepsForFrame is empty for a frame the chain never enters" $
      map stepLabel (stepsForFrame "no-such-frame" demoChain) @?= []
  ]
