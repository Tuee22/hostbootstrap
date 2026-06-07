-- | The @ensure cuda@ reconciler: the NVIDIA driver and container runtime on
-- @linux-gpu@.
module HostBootstrap.Ensure.Cuda (reconciler) where

import Data.List (isInfixOf)
import HostBootstrap.Ensure (Reconciler (..), runTool, toolPresent)
import HostBootstrap.HostTool (HostTool (Docker, NvidiaSmi))
import HostBootstrap.Substrate (hasGpu)
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
          then die "ensure cuda: nvidia-smi not found; install the NVIDIA driver."
          else do
            smi <- runTool cfg NvidiaSmi ["-L"]
            case smi of
              Right (ExitSuccess, _, _) -> do
                runtimes <- runTool cfg Docker ["info", "--format", "{{json .Runtimes}}"]
                case runtimes of
                  Right (_, out, _)
                    | "nvidia" `isInfixOf` out ->
                        putStrLn "ensure cuda: NVIDIA driver and Docker runtime present (no-op)"
                  _ ->
                    die
                      "ensure cuda: NVIDIA container toolkit is not registered with Docker. Install nvidia-container-toolkit and re-configure dockerd."
              _ -> die "ensure cuda: nvidia-smi did not report a GPU."
    }
