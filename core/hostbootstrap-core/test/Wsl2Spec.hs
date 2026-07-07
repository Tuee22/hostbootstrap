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
        wslShutdownArgs @?= ["--shutdown"],
      testCase "mergeWslConfig preserves other sections and replaces [wsl2]" $ do
        let body = ["[wsl2]", "processors=6", "memory=10GB", "swap=10GB"]
        -- an empty/absent .wslconfig yields just our block
        mergeWslConfig "" body @?= "[wsl2]\nprocessors=6\nmemory=10GB\nswap=10GB\n"
        -- a user's other sections survive; the old [wsl2] block is replaced, not duplicated
        let existing = "[experimental]\nsparseVhd=true\n\n[wsl2]\nmemory=4GB\nprocessors=2\n"
            merged = mergeWslConfig existing body
        assertBool "keeps [experimental]" ("[experimental]" `elemLine` merged)
        assertBool "keeps the user's experimental key" ("sparseVhd=true" `elemLine` merged)
        assertBool "applies our processors" ("processors=6" `elemLine` merged)
        assertBool "drops the old memory value" (not ("memory=4GB" `elemLine` merged))
        assertBool "exactly one [wsl2] header" (length (filter (== "[wsl2]") (lines merged)) == 1)
        -- idempotent: re-merging our own output replaces [wsl2] in place, not appends
        assertBool "idempotent [wsl2]" (length (filter (== "[wsl2]") (lines (mergeWslConfig merged body))) == 1),
      testCase "mergeWslConfig manages both [general] and [wsl2], preserving unrelated sections" $ do
        let body = ["[general]", "instanceIdleTimeout=-1", "[wsl2]", "processors=6", "vmIdleTimeout=-1"]
        -- both managed sections are written from an empty file
        mergeWslConfig "" body @?= "[general]\ninstanceIdleTimeout=-1\n[wsl2]\nprocessors=6\nvmIdleTimeout=-1\n"
        -- an unrelated user section survives; the user's own [general]/[wsl2] keys are replaced
        let existing = "[experimental]\nsparseVhd=true\n\n[general]\ndistro=old\n\n[wsl2]\nmemory=4GB\n"
            merged = mergeWslConfig existing body
        assertBool "keeps unrelated [experimental] key" ("sparseVhd=true" `elemLine` merged)
        assertBool "applies instanceIdleTimeout" ("instanceIdleTimeout=-1" `elemLine` merged)
        assertBool "replaces the user's [general] key" (not ("distro=old" `elemLine` merged))
        assertBool "replaces the user's [wsl2] key" (not ("memory=4GB" `elemLine` merged))
        assertBool "exactly one [general] header" (length (filter (== "[general]") (lines merged)) == 1)
        assertBool "exactly one [wsl2] header" (length (filter (== "[wsl2]") (lines merged)) == 1),
      testCase "wsl -l -v parsers: distro states + running filter (UTF-16 NUL, * marker, header)" $ do
        let raw = utf16ish "  NAME                     STATE           VERSION\n* hostbootstrap-demo-vm    Running         2\nUbuntu                     Stopped         2\n"
        wslDistroStates raw @?= [("hostbootstrap-demo-vm", "running"), ("Ubuntu", "stopped")]
        wslRunningDistros raw @?= ["hostbootstrap-demo-vm"]
        -- a stopped managed distro is NOT reported running (the killed-run case the fix targets)
        wslRunningDistros (utf16ish "  NAME                     STATE      VERSION\n* hostbootstrap-demo-vm    Stopped    2\n") @?= []
    ]

elemLine :: String -> String -> Bool
elemLine needle = elem needle . lines

utf16ish :: String -> String
utf16ish =
  concatMap (\c -> [c, '\0'])
