-- | The @ensure cuda@ reconciler: the NVIDIA driver and container runtime on
-- @linux-gpu@.
--
-- Install-and-verify (see @development_plan_standards.md § L@): the kernel
-- driver (@nvidia-smi@) is a precondition — a kernel driver is not auto-installed
-- here — but the NVIDIA container toolkit and its Docker runtime registration are
-- installed and verified. A verified no-op when the driver is present and the
-- @nvidia@ runtime is already registered with Docker. The pure 'installSteps'
-- planner is unit-tested.
module HostBootstrap.Ensure.Cuda (reconciler, installSteps) where

import Data.List (isInfixOf)
import HostBootstrap.Ensure
  ( InstallStep (..),
    Reconciler (..),
    installAndVerify,
    runTool,
    toolPresent,
  )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Docker, NvidiaSmi, Sudo))
import HostBootstrap.Substrate
  ( Substrate,
    SubstrateName (LinuxGpu),
    hasGpu,
    renderSubstrateName,
    substrateName,
  )
import System.Exit (ExitCode (..), die)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "cuda",
      reconcilerSummary = "Ensure the NVIDIA driver and Docker runtime (linux-gpu)",
      appliesTo = hasGpu,
      requirement = "linux-gpu",
      reconcile = \cfg ->
        if not (toolPresent cfg NvidiaSmi)
          then die "ensure cuda: nvidia-smi not found; install the NVIDIA driver, then re-run."
          else installAndVerify "cuda" satisfied installSteps cfg
    }

-- | CUDA is satisfied when @nvidia-smi -L@ reports a GPU and the @nvidia@ runtime
-- is registered with Docker.
satisfied :: HostConfig -> IO Bool
satisfied cfg = do
  smi <- runTool cfg NvidiaSmi ["-L"]
  case smi of
    Right (ExitSuccess, out, _) | "GPU" `isInfixOf` out -> do
      runtimes <- runTool cfg Docker ["info", "--format", "{{json .Runtimes}}"]
      pure $ case runtimes of
        Right (_, rOut, _) -> "nvidia" `isInfixOf` rOut
        _ -> False
    _ -> pure False

-- | The substrate-branched install plan: install the NVIDIA container toolkit,
-- register the @nvidia@ runtime with Docker, and restart the daemon.
installSteps :: Substrate -> Either String [InstallStep]
installSteps sub
  | substrateName sub == LinuxGpu =
      Right
        [ InstallStep Sudo ["apt-get", "install", "-y", "nvidia-container-toolkit"],
          InstallStep Sudo ["nvidia-ctk", "runtime", "configure", "--runtime=docker"],
          InstallStep Sudo ["systemctl", "restart", "docker"]
        ]
  | otherwise =
      Left ("cuda is only applicable on linux-gpu, not " ++ renderSubstrateName (substrateName sub))
