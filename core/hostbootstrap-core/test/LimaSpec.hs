module LimaSpec (tests) where

import Data.Either (isLeft)
import HostBootstrap.Lima
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

vm :: LimaVM
vm = LimaVM "hostbootstrap-demo-vm"

tests :: TestTree
tests =
    testGroup
        "LimaSpec"
        [ testGroup "VM argv builders" argvCases
        , testGroup "name-prefix delete-guard" guardCases
        ]

argvCases :: [TestTree]
argvCases =
    [ testCase "start uses the named Ubuntu 24.04 template" $
        startVMArgs vm ["--cpus", "4", "--memory", "8", "--disk", "20"]
            @?= ["start", "-y", "--timeout", "15m", "--name=hostbootstrap-demo-vm", "--containerd", "none", "--cpus", "4", "--memory", "8", "--disk", "20", "template:ubuntu-24.04"]
    , testCase "shell dispatches a bare in-VM command through limactl shell" $
        shellVMArgs vm ["docker", "info"]
            @?= ["shell", "hostbootstrap-demo-vm", "--", "docker", "info"]
    , testCase "copy targets the named instance" $
        copyToVMArgs vm "/tmp/src.tgz" "/tmp/src.tgz"
            @?= ["copy", "/tmp/src.tgz", "hostbootstrap-demo-vm:/tmp/src.tgz"]
    , testCase "status targets the named instance" $
        statusVMArgs vm @?= ["list", "--format", "json", "hostbootstrap-demo-vm"]
    ]

guardCases :: [TestTree]
guardCases =
    [ testCase "a prefixed VM name is destroyable" $
        deleteVMArgs "hostbootstrap-demo-" vm
            @?= Right ["delete", "hostbootstrap-demo-vm", "--force"]
    , testCase "a non-prefixed instance is refused" $
        assertBool "refuses to delete" (isLeft (deleteVMArgs "other-prefix-" vm))
    ]
