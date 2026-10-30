{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HostToolSpec (tests, windowsResolutionSupported) where

import ConditionalCase (conditionalCase)
import Control.Exception (try)
import Control.Monad (forM_)
import Data.Char (chr, toLower)
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as Map
import HostBootstrap.Effect (CapturedRun (..), runCaptured)
import HostBootstrap.HostConfig (
    HostConfig (..),
    HostToolError (..),
    resolve,
    resolveInstalled,
    resolveMaybe,
 )
import HostBootstrap.HostTool
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import PlatformPath (hostFixturePath)
import qualified SourceGuard
import System.Directory (doesFileExist, pathIsSymbolicLink)
import System.Environment (getEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (dropExtension, isAbsolute, takeDirectory, takeFileName, (</>))
import System.Info (os)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "HostToolSpec"
        [ testCase "a CUDA tool prefers the stable symlink, then newest versioned root" $
            cudaCandidatePaths "nvcc" ["bin", "cuda-12.4", "cuda-13.3", "share"]
                @?= [ "/usr/local/cuda/bin/nvcc"
                    , "/usr/local/cuda-13.3/bin/nvcc"
                    , "/usr/local/cuda-12.4/bin/nvcc"
                    ]
        , testCase "a prefix with no CUDA install still offers the stable symlink" $
            cudaCandidatePaths "nvcc" ["bin", "share"]
                @?= ["/usr/local/cuda/bin/nvcc"]
        , testGroup "AbsExe" absExeCases
        , testGroup "HostTool enumeration" enumCases
        , testGroup "resolution" resolutionCases
        , testGroup "Windows resolution" windowsResolutionCases
        , testCase "toolkit versions are ordered numerically newest first" $ do
            newestToolkitVersions ["cuda-9.2", "cuda-12.4", "cuda-12.9", "cuda-12.10"]
                @?= ["cuda-12.10", "cuda-12.9", "cuda-12.4", "cuda-9.2"]
            newestToolkitVersions ["v9.0", "v12.10", "v12.9", "v13.0"]
                @?= ["v13.0", "v12.10", "v12.9", "v9.0"]
            newestToolkitVersions ["14.29.30133", "14.40.33807"]
                @?= ["14.40.33807", "14.29.30133"]
            cudaCandidatePaths "nvcc" ["cuda-9.2", "cuda-12.4", "cuda-12.9", "cuda-12.10"]
                @?= ["/usr/local/cuda/bin/nvcc", "/usr/local/cuda-12.10/bin/nvcc", "/usr/local/cuda-12.9/bin/nvcc", "/usr/local/cuda-12.4/bin/nvcc", "/usr/local/cuda-9.2/bin/nvcc"]
        , testCase "the pre-binary minimums have no Haskell mirror" $
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                let roots = [packageRoot </> directory | directory <- ["src", "internal", "app"]]
                        <> [takeDirectory (takeDirectory packageRoot) </> "demo" </> "src"]
                sources <- concat <$> traverse SourceGuard.readHaskellSources roots
                forM_ sources $ \(path, source) -> do
                    SourceGuard.countHaskellIdentifier "checkHostMinimums" source
                        @?= 0
                    assertBool
                        ("the pre-binary floor is Python-owned: " <> path)
                        (SourceGuard.countHaskellTokenSequence ["module", "HostBootstrap", ".", "HostPrereqs"] source == 0)
        ]

absExeCases :: [TestTree]
absExeCases =
    [ testCase "absolute path accepted, preserved" $
        fmap absExePath (mkAbsExe dockerPath) @?= Right dockerPath
    , testCase "bare command name rejected" $
        isLeft (mkAbsExe "docker") @?= True
    , testCase "relative path rejected" $
        isLeft (mkAbsExe "./bin/docker") @?= True
    , testCase "WSL receives its resolved basename as the serialized program-name token" $ do
        let executable = mustAbs dockerPath
        hostToolProcessArguments Wsl executable ["-d", "demo"]
            @?= [takeFileName dockerPath, "-d", "demo"]
        hostToolProcessArguments Docker executable ["ps"] @?= ["ps"]
    ]

enumCases :: [TestTree]
enumCases =
    [ testCase "every tool has a non-empty bare name without a slash" $
        assertBool "names are bare commands" $
            all (\t -> let n = toolCommandName t in not (null n) && '/' `notElem` n && chr 92 `notElem` n) allHostTools
    , testCase "the closed set is exactly the tools the binary delegates to" $
        allHostTools
            @?= [ Docker
                , Colima
                , Lima
                , Brew
                , Ghc
                , Ghcup
                , Kubectl
                , Helm
                , Kind
                , Nvkind
                , Mc
                , NvidiaSmi
                , Nvcc
                , Swiftc
                , Xcrun
                , SystemProfiler
                , Clang
                , Clangxx
                , MsvcCl
                , Vswhere
                , PowerShell
                , Bcdedit
                , Sysctl
                , Winget
                , Wsl
                , Sudo
                , XcodeSelect
                , Incus
                , Df
                , Kill
                , Ps
                , Tar
                , Curl
                , Virtiofsd
                ]
    , testCase "Curl has the canonical command name" $
        toolCommandName Curl @?= "curl"
    , testCase "Virtiofsd has the canonical command name" $
        toolCommandName Virtiofsd @?= "virtiofsd"
    ]

resolutionCases :: [TestTree]
resolutionCases =
    [ testCase "resolve returns the configured absolute path" $ do
        exe <- resolve cfg Docker
        absExePath exe @?= dockerPath
        assertBool "resolved path is absolute" (isAbsolute (absExePath exe))
    , testCase "resolveMaybe is Nothing for an unconfigured tool" $
        resolveMaybe cfg Helm @?= Nothing
    , testCase "Curl resolves through its configured absolute path" $
        assertResolved Curl curlPath
    , testCase "Curl uses the standard missing-tool error" $ do
        resolveMaybe cfg Curl @?= Nothing
        assertUnresolved Curl
    , testCase "Virtiofsd resolves through its configured absolute path" $
        assertResolved Virtiofsd virtiofsdPath
    , testCase "Virtiofsd uses the standard missing-tool error" $ do
        resolveMaybe cfg Virtiofsd @?= Nothing
        assertUnresolved Virtiofsd
    , testCase "resolve throws HostToolError for an unconfigured tool" $ do
        result <- try (resolve cfg Helm) :: IO (Either HostToolError AbsExe)
        case result of
            Left (UnresolvedTool Helm) -> pure ()
            other -> assertBool ("expected UnresolvedTool Helm, got " ++ show other) False
    , testCase "resolveInstalled prefers the configured path over re-measuring the host" $ do
        let absent = hostFixturePath "/nonexistent/hostbootstrap-configured/docker"
            configured = cfg{hcToolPaths = Map.singleton Docker (mustAbs absent)}
        resolved <- resolveInstalled configured Docker
        fmap absExePath resolved @?= Just absent
    , testCase "resolveInstalled re-measures the host for a tool the configuration predates" $ do
        -- The pristine-host ordering the authenticated descent hit: the chain's
        -- own `ensure` step installs the provider after this configuration was
        -- measured, so the typed lookup is empty and the host is not. Both
        -- answers must agree with `discover`, whether the tool is present on
        -- this gate host or not, and neither may be a bare command name.
        sequence_
            [ do
                discovered <- discover tool
                resolved <- resolveInstalled empty tool
                fmap absExePath resolved @?= fmap absExePath discovered
                assertBool
                    ("a re-measured path is absolute: " ++ toolCommandName tool)
                    (all (isAbsolute . absExePath) resolved)
            | tool <- allHostTools
            ]
    , testCase "every discovered executable is an absolute file or a verified native app alias" $
        forM_ allHostTools $ \tool -> do
            found <- discover tool
            forM_ found $ \executable -> do
                let path = absExePath executable
                    stem = map toLower (dropExtension (toolCommandName tool))
                assertBool ("discovery must return an absolute path for " <> show tool) (isAbsolute path)
                present <- doesFileExist path
                if present
                    then pure ()
                    else
                        if windowsResolutionSupported && tool == Winget
                            then do
                                -- Windows AppExecutionAlias entries are reparse
                                -- points that directory's file predicate cannot
                                -- follow. A real launch verifies their target.
                                nativeAlias <- pathIsSymbolicLink path
                                assertBool ("Winget must be a native alias: " <> path) nativeAlias
                                outcome <- runCaptured path ["--version"] ""
                                case outcome of
                                    Right run ->
                                        assertBool
                                            ("the native Winget alias must launch and identify itself: " <> path <> ": " <> show run)
                                            (capturedExit run == ExitSuccess && not (null (capturedStdout run)))
                                    Left failure -> assertFailure ("the native Winget alias could not launch: " <> show failure)
                            else assertFailure ("discovery must return an existing file for " <> show tool <> ": " <> path)
                assertBool ("discovery basename must name " <> show tool <> ": " <> path)
                    (isPrefixOf stem (map toLower (takeFileName path)))
    , testCase "accelerator tools resolve only through configured absolute paths" $ do
        sequence_
            [ assertResolved Swiftc swiftcPath
            , assertResolved Xcrun xcrunPath
            , assertResolved SystemProfiler systemProfilerPath
            , assertResolved Clang clangPath
            , assertResolved Clangxx clangxxPath
            , assertResolved MsvcCl msvcClPath
            , assertResolved Vswhere vswherePath
            ]
    , testCase "accelerator tools use the standard missing-tool error" $ do
        sequence_
            [ assertUnresolved Swiftc
            , assertUnresolved Xcrun
            , assertUnresolved SystemProfiler
            , assertUnresolved Clang
            , assertUnresolved Clangxx
            , assertUnresolved MsvcCl
            , assertUnresolved Vswhere
            ]
    ]
  where
    cfg =
        HostConfig
            { hcSubstrate = Substrate LinuxCpu Amd64
            , hcToolPaths =
                Map.fromList
                    [ (Docker, mustAbs dockerPath)
                    , (Sudo, mustAbs sudoPath)
                    ]
            }

    empty =
        HostConfig
            { hcSubstrate = Substrate LinuxCpu Amd64
            , hcToolPaths = Map.empty
            }

    configuredCfg =
        HostConfig
            { hcSubstrate = Substrate LinuxCpu Amd64
            , hcToolPaths =
                Map.fromList
                    [ (Swiftc, mustAbs swiftcPath)
                    , (Xcrun, mustAbs xcrunPath)
                    , (SystemProfiler, mustAbs systemProfilerPath)
                    , (Clang, mustAbs clangPath)
                    , (Clangxx, mustAbs clangxxPath)
                    , (MsvcCl, mustAbs msvcClPath)
                    , (Vswhere, mustAbs vswherePath)
                    , (Curl, mustAbs curlPath)
                    , (Virtiofsd, mustAbs virtiofsdPath)
                    ]
            }

    curlPath = hostFixturePath "/configured/bin/curl"
    virtiofsdPath = hostFixturePath "/configured/libexec/virtiofsd"

    assertResolved tool expected = do
        exe <- resolve configuredCfg tool
        absExePath exe @?= expected
        assertBool "resolved tool path is absolute" (isAbsolute (absExePath exe))

    assertUnresolved tool = do
        result <- try (resolve cfg tool) :: IO (Either HostToolError AbsExe)
        case result of
            Left (UnresolvedTool missing) | missing == tool -> pure ()
            other -> assertBool ("expected UnresolvedTool " ++ show tool ++ ", got " ++ show other) False

windowsResolutionSupported :: Bool
windowsResolutionSupported = os == "mingw32"

windowsResolutionCases :: [TestTree]
windowsResolutionCases =
    [ systemToolCase "Windows WSL discovery prefers the System32 executable over the app alias" Wsl "wsl.exe"
    , systemToolCase "Windows bcdedit discovery resolves the System32 executable" Bcdedit "bcdedit.exe"
    ]
  where
    systemToolCase label tool name =
        conditionalCase ["HostToolSpec", "Windows resolution"] windowsResolutionSupported label
            (do
                root <- getEnv "SystemRoot"
                discovered <- discover tool
                fmap absExePath discovered @?= Just (root </> "System32" </> name)
            )
            (discover tool >>= (@?= Nothing))

#ifdef mingw32_HOST_OS
dockerPath :: FilePath
dockerPath = "C:\\Program Files\\Docker\\Docker\\resources\\bin\\docker.exe"

sudoPath :: FilePath
sudoPath = "C:\\Windows\\System32\\sudo.exe"

swiftcPath :: FilePath
swiftcPath = "C:\\Tools\\Swift\\bin\\swiftc.exe"

xcrunPath :: FilePath
xcrunPath = "C:\\Tools\\Xcode\\usr\\bin\\xcrun.exe"

systemProfilerPath :: FilePath
systemProfilerPath = "C:\\Tools\\Xcode\\usr\\bin\\system_profiler.exe"

clangPath :: FilePath
clangPath = "C:\\Program Files\\LLVM\\bin\\clang.exe"

clangxxPath :: FilePath
clangxxPath = "C:\\Program Files\\LLVM\\bin\\clang++.exe"

msvcClPath :: FilePath
msvcClPath = "C:\\Program Files\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\MSVC\\14.40.33807\\bin\\Hostx64\\x64\\cl.exe"

vswherePath :: FilePath
vswherePath = "C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe"
#else
dockerPath :: FilePath
dockerPath = "/usr/bin/docker"

sudoPath :: FilePath
sudoPath = "/usr/bin/sudo"

swiftcPath :: FilePath
swiftcPath = "/usr/bin/swiftc"

xcrunPath :: FilePath
xcrunPath = "/usr/bin/xcrun"

systemProfilerPath :: FilePath
systemProfilerPath = "/usr/sbin/system_profiler"

clangPath :: FilePath
clangPath = "/usr/bin/clang"

clangxxPath :: FilePath
clangxxPath = "/usr/bin/clang++"

msvcClPath :: FilePath
msvcClPath = "/opt/msvc/bin/cl.exe"

vswherePath :: FilePath
vswherePath = "/opt/vs/Installer/vswhere.exe"
#endif

mustAbs :: FilePath -> AbsExe
mustAbs = either error id . mkAbsExe

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
