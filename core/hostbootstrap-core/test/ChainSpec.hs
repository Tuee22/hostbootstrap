{-# LANGUAGE OverloadedStrings #-}

module ChainSpec (tests) where

import HostBootstrap.Chain
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.HostTool (HostTool (Docker, Incus))
import HostBootstrap.Incus (IncusVM (..))
import HostBootstrap.Lift
  ( ContainerLift (..),
    LiftDispatch (DispatchTool),
    SelfRef,
    inContainer,
    inVM,
    localContext,
    mkSelfRef,
  )
import HostBootstrap.Step
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ChainSpec"
    [ testGroup "nextFrameAfter (descent order)" nextFrameCases,
      testGroup "handoffDispatch (recursive `project up` handoff)" handoffCases,
      testGroup "renderChain is the single representation" renderCases
    ]

-- Fixtures.
metal :: StepFrame
metal = StepFrame {frameId = "host-orchestrator-0", frameLabel = "metal"}

vmFrame :: StepFrame
vmFrame = StepFrame {frameId = "vm-orchestrator-1", frameLabel = "VM"}

ctrFrame :: StepFrame
ctrFrame = StepFrame {frameId = "vm-project-container-2", frameLabel = "container"}

noop :: a -> IO ()
noop _ = pure ()

demoChain :: [Step]
demoChain =
  [ deployVMStep "launch the VM" metal noop,
    copySourceStep "stage source into the VM" metal noop,
    buildPbStep "build the binary in the VM" metal noop,
    contextInitStep "mint the container config" vmFrame noop,
    buildImageStep "build the project image" vmFrame noop,
    deployKindStep "bring up kind" ctrFrame noop,
    projectStep "deploy-harbor" "install harbor" ctrFrame noop,
    exposePortStep "expose the NodePort" ctrFrame noop
  ]

self :: SelfRef
self = mkSelfRef "/proc/self/exe" "/usr/local/bin/hostbootstrap-demo"

vm :: IncusVM
vm = IncusVM "demo-vm" "images:ubuntu/24.04"

sockMount :: V.Mount
sockMount = V.Mount {V.source = "/var/run/docker.sock", V.target = "/var/run/docker.sock", V.readOnly = False}

container :: ContainerLift
container =
  ContainerLift
    { clImage = "demo:local",
      clMounts = [sockMount],
      clExtraArgs = ["--network=host"],
      clRemoveAfter = True
    }

nextFrameCases :: [TestTree]
nextFrameCases =
  [ testCase "hands off from the metal frame to the VM frame" $
      nextFrameAfter "host-orchestrator-0" demoChain @?= Just vmFrame,
    testCase "hands off from the VM frame to the container frame" $
      nextFrameAfter "vm-orchestrator-1" demoChain @?= Just ctrFrame,
    testCase "bottoms out at the innermost frame" $
      nextFrameAfter "vm-project-container-2" demoChain @?= Nothing,
    testCase "a frame the chain never enters has no next frame" $
      nextFrameAfter "no-such-frame" demoChain @?= Nothing
  ]

handoffCases :: [TestTree]
handoffCases =
  [ testCase "into a VM: incus exec -- <in-vm pb> project up" $
      handoffDispatch self (inVM vm localContext)
        @?= DispatchTool Incus ["exec", "demo-vm", "--", "/usr/local/bin/hostbootstrap-demo", "project", "up"],
    testCase "into a container: docker run --rm img project up (ENTRYPOINT is the pb)" $
      handoffDispatch self (inContainer container localContext)
        @?= DispatchTool
          Docker
          [ "run",
            "--rm",
            "-v",
            "/var/run/docker.sock:/var/run/docker.sock",
            "--network=host",
            "demo:local",
            "project",
            "up"
          ]
  ]

renderCases :: [TestTree]
renderCases =
  [ testCase "the dry-run plan lists every step the interpreter would run, in order" $
      renderChain demoChain
        @?= unlines
          [ "1. [host-orchestrator-0] deploy-vm — launch the VM",
            "2. [host-orchestrator-0] copy-source — stage source into the VM",
            "3. [host-orchestrator-0] build-pb — build the binary in the VM",
            "4. [vm-orchestrator-1] context-init — mint the container config",
            "5. [vm-orchestrator-1] build-image — build the project image",
            "6. [vm-project-container-2] deploy-kind — bring up kind",
            "7. [vm-project-container-2] deploy-harbor — install harbor",
            "8. [vm-project-container-2] expose-port — expose the NodePort"
          ],
    testCase "frame-segmenting the chain across the descent preserves every step in order" $
      concatMap (\f -> map stepLabel (stepsForFrame (frameId f) demoChain)) (chainFrames demoChain)
        @?= map stepLabel demoChain
  ]
