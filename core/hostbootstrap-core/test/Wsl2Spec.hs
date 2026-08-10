module Wsl2Spec (tests) where

import Data.Either (isLeft)
import Data.List (isInfixOf, isPrefixOf)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Wsl2
import qualified SourceGuard
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Wsl2Spec"
    [ testGroup "lifecycle builders and classifiers" lifecycleCases,
      testGroup "provider realization boundary" providerBoundaryCases
    ]

lifecycleCases :: [TestTree]
lifecycleCases =
  [ testCase "platform diagnostic classifiers" $ do
      assertBool "detects WSL virtualization startup diagnostic" $
        wslReportsVirtualizationDisabled (ExitSuccess, "WSL2 is unable to start since virtualization is not enabled", "")
      assertBool "detects UTF-16-shaped WSL virtualization startup diagnostic" $
        wslReportsVirtualizationDisabled (ExitSuccess, utf16ish "WSL2 is unable to start since virtualization is not enabled", "")
      assertBool "detects the no-installed-distributions diagnostic" $
        wslReportsNoInstalledDistributions (ExitSuccess, utf16ish "Windows Subsystem for Linux has no installed distributions.", ""),
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
    testCase "wsl list parsers handle UTF-16 NULs, the default marker, and the header" $ do
      let raw = utf16ish "  NAME                     STATE           VERSION\n* hostbootstrap-demo-vm    Running         2\nUbuntu                     Stopped         2\n"
      wslListDistros (utf16ish "hostbootstrap-demo-vm\nUbuntu\n") @?= ["hostbootstrap-demo-vm", "Ubuntu"]
      wslDistroStates raw @?= [("hostbootstrap-demo-vm", "running"), ("Ubuntu", "stopped")]
      wslRunningDistros raw @?= ["hostbootstrap-demo-vm"]
      -- A stopped managed distro is not reported running (the killed-run case the fix targets).
      wslRunningDistros (utf16ish "  NAME                     STATE      VERSION\n* hostbootstrap-demo-vm    Stopped    2\n") @?= []
  ]

providerBoundaryCases :: [TestTree]
providerBoundaryCases =
  [ testCase "Wsl2 consumes the lower target/renderer and delegates prerequisite helpers" $ do
      source <- providerSource "Wsl2.hs"
      hostBootstrapImports source
        @?= ["HostBootstrap.Ensure.Wsl2", "HostBootstrap.Lift.Context"]
      fmap withoutCommas (SourceGuard.moduleImportTokens "HostBootstrap.Lift.Context" source)
        @?= Just ["Wsl2VM", "(", "..", ")", "wslExecArgs"]
      fmap withoutCommas (SourceGuard.moduleImportTokens "HostBootstrap.Ensure.Wsl2" source)
        @?= Just prerequisiteHelpers
      exports <-
        maybe
          (fail "HostBootstrap.Wsl2 must have an explicit export list")
          pure
          (SourceGuard.moduleExportTokens "HostBootstrap.Wsl2" source)
      assertBool "Wsl2VM (..) is not reexported" (["Wsl2VM", "(", "..", ")"] `isInfixOf` exports)
      assertBool "wslExecArgs is not reexported" ("wslExecArgs" `elem` exports)
      mapM_ (\helper -> assertBool (helper ++ " is not reexported") (helper `elem` exports)) prerequisiteHelpers
      SourceGuard.countHaskellTokenSequence ["data", "Wsl2VM"] source @?= 0
      SourceGuard.countHaskellTokenSequence ["newtype", "Wsl2VM"] source @?= 0
      SourceGuard.countHaskellTokenSequence ["wslExecArgs", "::"] source @?= 0
      mapM_ (\helper -> SourceGuard.countHaskellTokenSequence [helper, "::"] source @?= 0) prerequisiteHelpers
      assertNoParallelLift source
  ]

prerequisiteHelpers :: [String]
prerequisiteHelpers =
  [ "bcdeditHypervisorLaunchArgs",
    "normalizeWslText",
    "wslReportsNoInstalledDistributions",
    "wslReportsVirtualizationDisabled"
  ]

providerSource :: FilePath -> IO String
providerSource sourceFile = do
  cwd <- getCurrentDirectory
  root <- findRepoRoot cwd >>= maybe (fail ("could not locate repository root from " ++ cwd)) pure
  readFile (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> sourceFile)

hostBootstrapImports :: String -> [String]
hostBootstrapImports = filter ("HostBootstrap." `isPrefixOf`) . SourceGuard.haskellImports

withoutCommas :: [String] -> [String]
withoutCommas = filter (/= ",")

assertNoParallelLift :: String -> IO ()
assertNoParallelLift source =
  mapM_
    ( \identifier ->
        SourceGuard.countHaskellIdentifier identifier source
          @?= 0
    )
    ["foldLift", "foldLeaf", "LiftContext", "DispatchLocal", "DispatchTool", "SubstrateProvider"]

utf16ish :: String -> String
utf16ish =
  concatMap (\c -> [c, '\0'])
