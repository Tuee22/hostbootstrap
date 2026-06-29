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
    [ testCase "readiness classifier" $ do
        classifyWsl2Readiness (ExitSuccess, "", "") @?= Ready
        classifyWsl2Readiness (ExitSuccess, "Default Version: 2\nWSL2 is unable to start since virtualization is not enabled", "") @?= Unsatisfiable
        classifyWsl2Readiness (ExitFailure (-1), "Windows Subsystem for Linux has no installed distributions.", "") @?= Ready
        classifyWsl2Readiness (ExitFailure 1, "Restart required", "") @?= NeedsReboot
        classifyWsl2Readiness (ExitFailure 1, "", "unsupported") @?= Unsatisfiable
        assertBool "detects WSL virtualization startup diagnostic" $
          wslReportsVirtualizationDisabled (ExitSuccess, "WSL2 is unable to start since virtualization is not enabled", "")
        assertBool "detects UTF-16-shaped WSL virtualization startup diagnostic" $
          wslReportsVirtualizationDisabled (ExitSuccess, utf16ish "WSL2 is unable to start since virtualization is not enabled", ""),
      testCase "pure lifecycle argv builders" $ do
        bcdeditHypervisorLaunchArgs @?= ["/set", "hypervisorlaunchtype", "auto"]
        wslInstallArgs "hostbootstrap-demo" "80GB"
          @?= ["--install", "-d", "Ubuntu-24.04", "--name", "hostbootstrap-demo", "--no-launch", "--vhd-size", "80GB"]
        wslImportArgs "hostbootstrap-demo" "C:\\hb\\wsl" "ubuntu.tar"
          @?= ["--import", "hostbootstrap-demo", "C:\\hb\\wsl", "ubuntu.tar", "--version", "2"]
        wslExecArgs "hostbootstrap-demo" ["hostbootstrap-demo", "project", "up"]
          @?= ["-d", "hostbootstrap-demo", "--", "hostbootstrap-demo", "project", "up"]
        wslTerminateArgs "hostbootstrap-demo" @?= ["--terminate", "hostbootstrap-demo"]
        wslUnregisterArgs "hostbootstrap-demo-" "hostbootstrap-demo-wsl"
          @?= Right ["--unregister", "hostbootstrap-demo-wsl"]
        assertBool "refuses to unregister unmanaged distro" (isLeft (wslUnregisterArgs "hostbootstrap-demo-" "personal-ubuntu"))
        wslShutdownArgs @?= ["--shutdown"]
    ]

utf16ish :: String -> String
utf16ish =
  concatMap (\c -> [c, '\0'])
