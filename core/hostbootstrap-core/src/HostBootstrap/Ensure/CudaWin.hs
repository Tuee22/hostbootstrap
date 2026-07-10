{- | The @ensure cudawin@ reconciler: CUDA as a Windows host-build capability.

CUDA-on-Windows is build-only in hostbootstrap's model. The NVIDIA driver is a
required precondition (the reconciler fails fast when @nvidia-smi@ is absent);
on top of it the CUDA Toolkit, MSVC build tools, and LLVM clang are readied on
the bare Windows host so nvcc artifacts can be produced and staged into the
cluster. The workload does not run in a Windows build VM.
-}
module HostBootstrap.Ensure.CudaWin (
    reconciler,
    installSteps,
    clangVersionArgs,
    vswhereVCToolsArgs,
    cudaSmokeCompileArgs,
    cudaSmokeSource,
)
where

import Control.Exception (SomeException)
import Control.Exception.Safe (try)
import Data.List (isInfixOf)
import HostBootstrap.Ensure (
    InstallStep (..),
    Reconciler (..),
    installAndVerify,
    runTool,
    toolPresent,
 )
import HostBootstrap.HostConfig (HostConfig, resolveMaybe)
import HostBootstrap.HostTool (HostTool (Clang, MsvcCl, Nvcc, NvidiaSmi, Vswhere, Winget), absExePath)
import HostBootstrap.Substrate (
    Substrate,
    SubstrateName (WindowsGpu),
    renderSubstrateName,
    substrateName,
 )
import System.Directory (
    createDirectoryIfMissing,
    getTemporaryDirectory,
    removePathForcibly,
 )
import System.Exit (ExitCode (..), die)
import System.FilePath (takeDirectory, (</>))

reconciler :: Reconciler
reconciler =
    Reconciler
        { reconcilerName = "cudawin"
        , reconcilerSummary = "Ensure CUDA host-build tooling on windows-gpu"
        , appliesTo = \sub -> substrateName sub == WindowsGpu
        , requirement = "windows-gpu"
        , reconcile = \cfg ->
            if not (toolPresent cfg NvidiaSmi)
                then die "ensure cudawin: nvidia-smi not found; install the NVIDIA driver, then re-run."
                else installAndVerify "cudawin" satisfied installSteps cfg
        }

{- | CUDA-on-Windows is satisfied when the Windows GPU driver reports a GPU and
the full daemon build stack can compile a tiny CUDA artifact with MSVC as
nvcc's host compiler.
-}
satisfied :: HostConfig -> IO Bool
satisfied cfg = do
    smi <- runTool cfg NvidiaSmi ["-L"]
    case smi of
        Right (ExitSuccess, out, _) | "GPU" `isInfixOf` out -> do
            clang <- toolOk cfg Clang clangVersionArgs
            vctools <- toolOutputNonEmpty cfg Vswhere vswhereVCToolsArgs
            smoke <- cudaSmokeCompile cfg
            pure (all (toolPresent cfg) [Nvcc, Clang, MsvcCl, Vswhere] && clang && vctools && smoke)
        _ -> pure False

toolOk :: HostConfig -> HostTool -> [String] -> IO Bool
toolOk cfg tool args = do
    result <- runTool cfg tool args
    pure $ case result of
        Right (ExitSuccess, _, _) -> True
        _ -> False

toolOutputNonEmpty :: HostConfig -> HostTool -> [String] -> IO Bool
toolOutputNonEmpty cfg tool args = do
    result <- runTool cfg tool args
    pure $ case result of
        Right (ExitSuccess, out, _) -> not (null (concat (words out)))
        _ -> False

cudaSmokeCompile :: HostConfig -> IO Bool
cudaSmokeCompile cfg =
    case resolveMaybe cfg MsvcCl of
        Nothing -> pure False
        Just clExe ->
            withProbeDir "hostbootstrap-cudawin-probe" $ \dir -> do
                let source = dir </> "cuda_smoke.cu"
                    exe = dir </> "cuda_smoke.exe"
                writeFile source cudaSmokeSource
                result <- runTool cfg Nvcc (cudaSmokeCompileArgs (takeDirectory (absExePath clExe)) source exe)
                pure $ case result of
                    Right (ExitSuccess, _, _) -> True
                    _ -> False

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
    | substrateName sub == WindowsGpu =
        Right
            [ InstallStep
                Winget
                ["install", "--id", "Nvidia.CUDA", "--exact", "--accept-package-agreements", "--accept-source-agreements"]
            , InstallStep
                Winget
                [ "install"
                , "--id"
                , "Microsoft.VisualStudio.2022.BuildTools"
                , "--exact"
                , "--accept-package-agreements"
                , "--accept-source-agreements"
                , "--override"
                , "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
                ]
            , InstallStep
                Winget
                ["install", "--id", "LLVM.LLVM", "--exact", "--accept-package-agreements", "--accept-source-agreements"]
            ]
    | otherwise =
        Left ("cudawin is only applicable on windows-gpu, not " ++ renderSubstrateName (substrateName sub))

clangVersionArgs :: [String]
clangVersionArgs = ["--version"]

vswhereVCToolsArgs :: [String]
vswhereVCToolsArgs =
    [ "-latest"
    , "-products"
    , "*"
    , "-requires"
    , "Microsoft.VisualStudio.Workload.VCTools"
    , "-property"
    , "installationPath"
    ]

cudaSmokeCompileArgs :: FilePath -> FilePath -> FilePath -> [String]
cudaSmokeCompileArgs msvcBin source output =
    [ "-ccbin"
    , msvcBin
    , source
    , "-o"
    , output
    ]

cudaSmokeSource :: String
cudaSmokeSource =
    unlines
        [ "#include <cuda_runtime.h>"
        , ""
        , "__global__ void hostbootstrap_probe_kernel(float *out) {"
        , "  *out = 1.0f;"
        , "}"
        , ""
        , "int main() {"
        , "  return 0;"
        , "}"
        ]
