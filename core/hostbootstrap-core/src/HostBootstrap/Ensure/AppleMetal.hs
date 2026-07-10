{- | The @ensure apple-metal@ reconciler: Apple Silicon Swift + Metal
host-build capability for the accelerator daemon.

The Metal runtime and macOS SDK are host-resident Apple capabilities. The
pre-binary host floor already requires Xcode Command Line Tools, so this
reconciler verifies the stack and fails fast with a remediation hint when the
CLT/SDK/Metal path is not usable. It does not require full Xcode, Tart,
keychain state, or a VM.
-}
module HostBootstrap.Ensure.AppleMetal (
    reconciler,
    installSteps,
    macosSdkArgs,
    systemProfilerMetalArgs,
    swiftMetalCompileArgs,
    swiftMetalProbeSource,
)
where

import Control.Exception (SomeException)
import Control.Exception.Safe (try)
import Data.List (isInfixOf)
import HostBootstrap.Ensure (
    InstallStep,
    Reconciler (..),
    installAndVerify,
    runTool,
    toolPresent,
 )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Swiftc, SystemProfiler, Xcrun))
import HostBootstrap.Substrate (
    Substrate,
    SubstrateName (AppleSilicon),
    renderSubstrateName,
    substrateName,
 )
import System.Directory (
    createDirectoryIfMissing,
    getTemporaryDirectory,
    removePathForcibly,
 )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

reconciler :: Reconciler
reconciler =
    Reconciler
        { reconcilerName = "apple-metal"
        , reconcilerSummary = "Ensure Swift + Metal host-build tooling on apple-silicon"
        , appliesTo = \sub -> substrateName sub == AppleSilicon
        , requirement = "apple-silicon"
        , reconcile = installAndVerify "apple-metal" satisfied installSteps
        }

satisfied :: HostConfig -> IO Bool
satisfied cfg
    | not (all (toolPresent cfg) [Swiftc, Xcrun, SystemProfiler]) = pure False
    | otherwise = do
        metal <- visibleMetalDevice cfg
        sdk <- macosSdkPath cfg
        case sdk of
            Nothing -> pure False
            Just sdkPath -> do
                smoke <- swiftMetalSmokeBuild cfg sdkPath
                pure (metal && smoke)

visibleMetalDevice :: HostConfig -> IO Bool
visibleMetalDevice cfg = do
    result <- runTool cfg SystemProfiler systemProfilerMetalArgs
    pure $ case result of
        Right (ExitSuccess, out, _) ->
            "Metal" `isInfixOf` out && not ("Unsupported" `isInfixOf` out)
        _ -> False

macosSdkPath :: HostConfig -> IO (Maybe FilePath)
macosSdkPath cfg = do
    result <- runTool cfg Xcrun macosSdkArgs
    pure $ case result of
        Right (ExitSuccess, out, _) ->
            case lines out of
                (path : _) | not (null path) -> Just path
                _ -> Nothing
        _ -> Nothing

swiftMetalSmokeBuild :: HostConfig -> FilePath -> IO Bool
swiftMetalSmokeBuild cfg sdkPath =
    withProbeDir "hostbootstrap-apple-metal-probe" $ \dir -> do
        let source = dir </> "MetalProbe.swift"
            exe = dir </> "metal-probe"
        writeFile source swiftMetalProbeSource
        compile <- runTool cfg Swiftc (swiftMetalCompileArgs sdkPath source exe)
        case compile of
            Right (ExitSuccess, _, _) -> do
                result <- try (readProcessWithExitCode exe [] "") :: IO (Either SomeException (ExitCode, String, String))
                pure $ case result of
                    Right (ExitSuccess, _, _) -> True
                    _ -> False
            _ -> pure False

withProbeDir :: FilePath -> (FilePath -> IO Bool) -> IO Bool
withProbeDir name action = do
    root <- getTemporaryDirectory
    let dir = root </> name
    _ <- try (removePathForcibly dir) :: IO (Either SomeException ())
    createDirectoryIfMissing True dir
    result <- try (action dir) :: IO (Either SomeException Bool)
    _ <- try (removePathForcibly dir) :: IO (Either SomeException ())
    pure (either (const False) id result)

installSteps :: Substrate -> Either String [InstallStep]
installSteps sub
    | substrateName sub == AppleSilicon =
        Left "Swift, xcrun, the macOS SDK, and Metal are supplied by Xcode Command Line Tools; run `xcode-select --install` and retry."
    | otherwise =
        Left ("apple-metal is only applicable on apple-silicon, not " ++ renderSubstrateName (substrateName sub))

macosSdkArgs :: [String]
macosSdkArgs = ["--sdk", "macosx", "--show-sdk-path"]

systemProfilerMetalArgs :: [String]
systemProfilerMetalArgs = ["SPDisplaysDataType"]

swiftMetalCompileArgs :: FilePath -> FilePath -> FilePath -> [String]
swiftMetalCompileArgs sdkPath source output =
    [ "-O"
    , "-sdk"
    , sdkPath
    , source
    , "-o"
    , output
    , "-framework"
    , "Metal"
    ]

swiftMetalProbeSource :: String
swiftMetalProbeSource =
    unlines
        [ "import Foundation"
        , "import Metal"
        , ""
        , "guard let device = MTLCreateSystemDefaultDevice() else {"
        , "  exit(1)"
        , "}"
        , ""
        , "print(device.name)"
        ]
