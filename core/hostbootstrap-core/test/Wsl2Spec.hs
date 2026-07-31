module Wsl2Spec (tests) where

import Data.Either (isLeft)
import HostBootstrap.Wsl2
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Wsl2Spec"
    [ testCase "platform diagnostic classifiers" $ do
        assertBool "detects WSL virtualization startup diagnostic" $
          wslReportsVirtualizationDisabled (ExitSuccess, "WSL2 is unable to start since virtualization is not enabled", "")
        assertBool "detects UTF-16-shaped WSL virtualization startup diagnostic" $
          wslReportsVirtualizationDisabled (ExitSuccess, utf16ish "WSL2 is unable to start since virtualization is not enabled", ""),
      testCase "pure lifecycle argv builders" $ do
        bcdeditHypervisorLaunchArgs @?= ["/set", "hypervisorlaunchtype", "auto"]
        wslInstallArgs "hostbootstrap-demo" "80GB"
          @?= ["--install", "-d", "Ubuntu-24.04", "--name", "hostbootstrap-demo", "--no-launch", "--vhd-size", "80GB"]
        wslExecArgs "hostbootstrap-demo" ["hostbootstrap-demo", "project", "up"]
          @?= ["-d", "hostbootstrap-demo", "--", "hostbootstrap-demo", "project", "up"]
        wslTerminateArgs "hostbootstrap-demo" @?= ["--terminate", "hostbootstrap-demo"]
        wslUnregisterArgs "hostbootstrap-demo-" "hostbootstrap-demo-wsl"
          @?= Right ["--unregister", "hostbootstrap-demo-wsl"]
        assertBool "refuses to unregister unmanaged distro" (isLeft (wslUnregisterArgs "hostbootstrap-demo-" "personal-ubuntu"))
        wslShutdownArgs @?= ["--shutdown"],
      testCase "wsl -l -v parsers: distro states + running filter (UTF-16 NUL, * marker, header)" $ do
        let raw = utf16ish "  NAME                     STATE           VERSION\n* hostbootstrap-demo-vm    Running         2\nUbuntu                     Stopped         2\n"
        wslDistroStates raw @?= [("hostbootstrap-demo-vm", "running"), ("Ubuntu", "stopped")]
        wslRunningDistros raw @?= ["hostbootstrap-demo-vm"]
        -- a stopped managed distro is NOT reported running (the killed-run case the fix targets)
        wslRunningDistros (utf16ish "  NAME                     STATE      VERSION\n* hostbootstrap-demo-vm    Stopped    2\n") @?= []
    ]

utf16ish :: String -> String
utf16ish =
  concatMap (\c -> [c, '\0'])
