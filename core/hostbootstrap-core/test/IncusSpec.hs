{-# LANGUAGE OverloadedStrings #-}

module IncusSpec (tests) where

import Data.Either (isLeft)
import HostBootstrap.Cluster.Cordon (incusSizingArgs)
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.Incus
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import System.Exit (ExitCode (..))

vm :: IncusVM
vm = IncusVM {vmName = "hostbootstrap-demo-vm", vmImage = "images:ubuntu/24.04"}

tests :: TestTree
tests =
  testGroup
    "IncusSpec"
    [ testGroup "VM argv builders" argvCases,
      testGroup "name-prefix delete-guard" guardCases,
      testGroup "reboot-to-ready classification" readinessCases,
      testGroup "incusSizingArgs" sizingCases
    ]

argvCases :: [TestTree]
argvCases =
  [ testCase "launch builds an image+name --vm argv with sizing appended" $
      createVMArgs vm ["limits.cpu=6"]
        @?= ["launch", "images:ubuntu/24.04", "hostbootstrap-demo-vm", "--vm", "limits.cpu=6"],
    testCase "exec dispatches a bare in-VM command through one incus exec" $
      execVMArgs vm ["docker", "info"]
        @?= ["exec", "hostbootstrap-demo-vm", "--", "docker", "info"],
    testCase "file push targets <name><dst>" $
      pushFileArgs vm "./wrapper.pyz" "/root/wrapper.pyz"
        @?= ["file", "push", "./wrapper.pyz", "hostbootstrap-demo-vm/root/wrapper.pyz"],
    testCase "restart reboots the guest" $
      rebootVMArgs vm @?= ["restart", "hostbootstrap-demo-vm"],
    testCase "stop halts the VM without deleting it (project down)" $
      stopVMArgs vm @?= ["stop", "hostbootstrap-demo-vm"]
  ]

guardCases :: [TestTree]
guardCases =
  [ testCase "a prefixed VM name is destroyable" $
      destroyVMArgs "hostbootstrap-demo-" vm
        @?= Right ["delete", "hostbootstrap-demo-vm", "--force"],
    testCase "a non-prefixed VM name is refused" $
      assertBool "refuses to delete" (isLeft (destroyVMArgs "other-prefix-" vm))
  ]

readinessCases :: [TestTree]
readinessCases =
  [ testCase "exit 0 is Ready" $
      classifyDockerReadiness (ExitSuccess, "ok", "") @?= Ready,
    testCase "a permission-denied failure is NeedsReboot" $
      classifyDockerReadiness (ExitFailure 1, "", "Got permission denied while trying to connect")
        @?= NeedsReboot,
    testCase "a missing-binary failure is Unsatisfiable" $
      classifyDockerReadiness (ExitFailure 127, "", "docker: command not found")
        @?= Unsatisfiable
  ]

sizingCases :: [TestTree]
sizingCases =
  [ testCase "incus sizing cordons cpu/memory/storage at the VM wall" $
      incusSizingArgs (ResourceEnvelope {cpu = 6, memory = "10GiB", storage = "40GiB"})
        @?= Right ["limits.cpu=6", "limits.memory=10GiB", "root,size=40GiB"]
  ]
