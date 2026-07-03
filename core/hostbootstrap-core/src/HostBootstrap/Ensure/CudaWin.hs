-- | The @ensure cudawin@ reconciler: CUDA as a Windows host-build capability.
--
-- CUDA-on-Windows is build-only in hostbootstrap's model. The NVIDIA driver is a
-- required precondition (the reconciler fails fast when @nvidia-smi@ is absent);
-- on top of it the CUDA Toolkit and MSVC build tools are readied on the bare
-- Windows host so nvcc artifacts can be produced and staged into the cluster. The
-- workload does not run in a Windows build VM.
module HostBootstrap.Ensure.CudaWin (reconciler, installSteps) where

import Data.List (isInfixOf)
import HostBootstrap.Ensure
  ( InstallStep (..),
    Reconciler (..),
    installAndVerify,
    runTool,
    toolPresent,
  )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Nvcc, NvidiaSmi, Winget))
import HostBootstrap.Substrate
  ( Substrate,
    SubstrateName (WindowsGpu),
    renderSubstrateName,
    substrateName,
  )
import System.Exit (ExitCode (..), die)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "cudawin",
      reconcilerSummary = "Ensure CUDA host-build tooling on windows-gpu",
      appliesTo = \sub -> substrateName sub == WindowsGpu,
      requirement = "windows-gpu",
      reconcile = \cfg ->
        if not (toolPresent cfg NvidiaSmi)
          then die "ensure cudawin: nvidia-smi not found; install the NVIDIA driver, then re-run."
          else installAndVerify "cudawin" satisfied installSteps cfg
    }

-- | CUDA-on-Windows is satisfied when the Windows GPU driver reports a GPU and
-- nvcc is on the resolved host-tool path.
satisfied :: HostConfig -> IO Bool
satisfied cfg = do
  smi <- runTool cfg NvidiaSmi ["-L"]
  pure $ case smi of
    Right (ExitSuccess, out, _) -> "GPU" `isInfixOf` out && toolPresent cfg Nvcc
    _ -> False

installSteps :: Substrate -> Either String [InstallStep]
installSteps sub
  | substrateName sub == WindowsGpu =
      Right
        [ InstallStep
            Winget
            ["install", "--id", "Nvidia.CUDA", "--exact", "--accept-package-agreements", "--accept-source-agreements"],
          InstallStep
            Winget
            ["install", "--id", "Microsoft.VisualStudio.2022.BuildTools", "--exact", "--accept-package-agreements", "--accept-source-agreements"]
        ]
  | otherwise =
      Left ("cudawin is only applicable on windows-gpu, not " ++ renderSubstrateName (substrateName sub))
