{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HostToolSpec (tests) where

import Control.Exception (try)
import qualified Data.Map.Strict as Map
import HostBootstrap.HostConfig
  ( HostConfig (..),
    HostToolError (..),
    resolve,
    resolveMaybe,
  )
import HostBootstrap.HostPrereqs (isUbuntu2404, parseOsRelease)
import HostBootstrap.HostTool
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import System.FilePath (isAbsolute)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "HostToolSpec"
    [ testGroup "AbsExe" absExeCases,
      testGroup "HostTool enumeration" enumCases,
      testGroup "resolution" resolutionCases,
      testGroup "HostPrereqs os-release" osReleaseCases
    ]

absExeCases :: [TestTree]
absExeCases =
  [ testCase "absolute path accepted, preserved" $
      fmap absExePath (mkAbsExe dockerPath) @?= Right dockerPath,
    testCase "bare command name rejected" $
      isLeft (mkAbsExe "docker") @?= True,
    testCase "relative path rejected" $
      isLeft (mkAbsExe "./bin/docker") @?= True
  ]

enumCases :: [TestTree]
enumCases =
  [ testCase "every tool has a non-empty bare name without a slash" $
      assertBool "names are bare commands" $
        all (\t -> let n = toolCommandName t in not (null n) && '/' `notElem` n) allHostTools,
    testCase "the closed set covers the documented tools" $
      assertBool "every documented HostTool constructor is in the closed set" $
        all
          (`elem` allHostTools)
          [Docker, Colima, Lima, Brew, Ghc, Ghcup, Kubectl, Helm, Kind, NvidiaSmi, Nvcc, PowerShell, Bcdedit, Sysctl, Winget, Wsl, Sudo, XcodeSelect, Incus, Df]
  ]

resolutionCases :: [TestTree]
resolutionCases =
  [ testCase "resolve returns the configured absolute path" $ do
      exe <- resolve cfg Docker
      absExePath exe @?= dockerPath
      assertBool "resolved path is absolute" (isAbsolute (absExePath exe)),
    testCase "resolveMaybe is Nothing for an unconfigured tool" $
      resolveMaybe cfg Helm @?= Nothing,
    testCase "resolve throws HostToolError for an unconfigured tool" $ do
      result <- try (resolve cfg Helm) :: IO (Either HostToolError AbsExe)
      case result of
        Left (UnresolvedTool Helm) -> pure ()
        other -> assertBool ("expected UnresolvedTool Helm, got " ++ show other) False,
    testCase "no resolved path is ever a bare command name" $
      assertBool "all configured paths absolute" $
        all (isAbsolute . absExePath) (Map.elems (hcToolPaths cfg))
  ]
    ++ windowsResolutionCases
  where
    cfg =
      HostConfig
        { hcSubstrate = Substrate LinuxCpu Amd64,
          hcToolPaths =
            Map.fromList
              [ (Docker, mustAbs dockerPath),
                (Sudo, mustAbs sudoPath)
              ]
        }

windowsResolutionCases :: [TestTree]
#ifdef mingw32_HOST_OS
windowsResolutionCases =
  [ testCase "Windows WSL discovery prefers the System32 executable over the app alias" $ do
      discovered <- discover Wsl
      fmap absExePath discovered @?= Just "C:\\Windows\\System32\\wsl.exe",
    testCase "Windows bcdedit discovery resolves the System32 executable" $ do
      discovered <- discover Bcdedit
      fmap absExePath discovered @?= Just "C:\\Windows\\System32\\bcdedit.exe"
  ]
#else
windowsResolutionCases = []
#endif

#ifdef mingw32_HOST_OS
dockerPath :: FilePath
dockerPath = "C:\\Program Files\\Docker\\Docker\\resources\\bin\\docker.exe"

sudoPath :: FilePath
sudoPath = "C:\\Windows\\System32\\sudo.exe"
#else
dockerPath :: FilePath
dockerPath = "/usr/bin/docker"

sudoPath :: FilePath
sudoPath = "/usr/bin/sudo"
#endif

osReleaseCases :: [TestTree]
osReleaseCases =
  [ testCase "parses KEY=VALUE and strips quotes" $
      lookup "ID" (parseOsRelease "ID=ubuntu\nVERSION_ID=\"24.04\"\n") @?= Just "ubuntu",
    testCase "ubuntu 24.04 recognised" $
      isUbuntu2404 "ID=ubuntu\nVERSION_ID=\"24.04\"\n" @?= True,
    testCase "ubuntu 22.04 rejected" $
      isUbuntu2404 "ID=ubuntu\nVERSION_ID=\"22.04\"\n" @?= False,
    testCase "debian rejected" $
      isUbuntu2404 "ID=debian\nVERSION_ID=\"12\"\n" @?= False
  ]

mustAbs :: FilePath -> AbsExe
mustAbs = either error id . mkAbsExe

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
