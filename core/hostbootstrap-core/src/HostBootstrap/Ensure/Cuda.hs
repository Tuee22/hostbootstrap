{- | The @ensure cuda@ reconciler: the NVIDIA driver and container runtime on
@linux-gpu@.

Install-and-verify (see @development_plan_standards.md § L@): the kernel
driver (@nvidia-smi@) is a precondition — a kernel driver is not auto-installed
here — but the NVIDIA container toolkit and its Docker runtime registration are
installed and verified. A verified no-op only when the exact @nvkind@
volume-mount injection path can see a GPU. The pure 'installSteps' planner and
probe classifier are unit-tested.
-}
module HostBootstrap.Ensure.Cuda (reconciler, installSteps, repositorySetupScript, nvidiaDriverProbeReady, nvkindRuntimeProbeArgs, nvkindRuntimeProbeReady) where

import Data.List (isInfixOf)
import HostBootstrap.Ensure (
    InstallStep (..),
    Reconciler (..),
    installAndVerify,
    runTool,
    toolPresent,
 )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Docker, NvidiaSmi, Sudo))
import HostBootstrap.Substrate (
    Substrate,
    SubstrateName (LinuxGpu),
    renderSubstrateName,
    substrateName,
 )
import System.Exit (ExitCode (..), die)

reconciler :: Reconciler
reconciler =
    Reconciler
        { reconcilerName = "cuda"
        , reconcilerSummary = "Ensure the NVIDIA driver and Docker runtime (linux-gpu)"
        , appliesTo = \sub -> substrateName sub == LinuxGpu
        , requirement = "linux-gpu"
        , reconcile = \cfg -> do
            if not (toolPresent cfg NvidiaSmi)
                then die "ensure cuda: nvidia-smi not found; install the NVIDIA driver, then re-run."
                else do
                    driver <- runTool cfg NvidiaSmi ["-L"]
                    if nvidiaDriverProbeReady driver
                        then installAndVerify "cuda" satisfied installSteps cfg
                        else die "ensure cuda: nvidia-smi did not report a GPU; repair the NVIDIA driver, then re-run."
        }

nvidiaDriverProbeReady :: Either String (ExitCode, String, String) -> Bool
nvidiaDriverProbeReady (Right (ExitSuccess, out, _)) = "GPU" `isInfixOf` out
nvidiaDriverProbeReady _ = False

{- | CUDA is satisfied when the host driver reports a GPU and the exact
@nvkind@ volume-mount injection smoke can see it from Docker. The latter proves
the NVIDIA runtime is the default, CDI is enabled, and
@accept-nvidia-visible-devices-as-volume-mounts@ is effective; merely listing
an @nvidia@ runtime is not sufficient for GPU-enabled kind nodes.
-}
satisfied :: HostConfig -> IO Bool
satisfied cfg = do
    smi <- runTool cfg NvidiaSmi ["-L"]
    case smi of
        result | nvidiaDriverProbeReady result -> do
            smoke <- runTool cfg Docker nvkindRuntimeProbeArgs
            pure (nvkindRuntimeProbeReady smoke)
        _ -> pure False

-- | NVIDIA's documented @nvkind@ toolkit smoke.
nvkindRuntimeProbeArgs :: [String]
nvkindRuntimeProbeArgs =
    [ "run"
    , "--rm"
    , "-v"
    , "/dev/null:/var/run/nvidia-container-devices/all"
    , "ubuntu:20.04"
    , "nvidia-smi"
    , "-L"
    ]

nvkindRuntimeProbeReady :: Either String (ExitCode, String, String) -> Bool
nvkindRuntimeProbeReady (Right (ExitSuccess, out, _)) = "GPU" `isInfixOf` out
nvkindRuntimeProbeReady _ = False

{- | The substrate-branched install plan: install the NVIDIA container toolkit,
register it as Docker's default with CDI, enable the volume-mount injection
@nvkind@ consumes, and restart the daemon.
-}
installSteps :: Substrate -> Either String [InstallStep]
installSteps sub
    | substrateName sub == LinuxGpu =
        Right
            [ InstallStep Sudo ["apt-get", "update"]
            , InstallStep Sudo ["apt-get", "install", "-y", "--no-install-recommends", "curl", "gnupg2"]
            , InstallStep Sudo ["/bin/sh", "-c", repositorySetupScript]
            , InstallStep Sudo ["apt-get", "update"]
            , InstallStep Sudo ["apt-get", "install", "-y", "nvidia-container-toolkit"]
            , InstallStep Sudo ["nvidia-ctk", "runtime", "configure", "--runtime=docker", "--set-as-default", "--cdi.enabled"]
            , InstallStep Sudo ["nvidia-ctk", "config", "--set", "accept-nvidia-visible-devices-as-volume-mounts=true", "--in-place"]
            , InstallStep Sudo ["systemctl", "restart", "docker"]
            ]
    | otherwise =
        Left ("cuda is only applicable on linux-gpu, not " ++ renderSubstrateName (substrateName sub))

{- | NVIDIA's signed Debian repository setup, expressed as one fail-closed root
shell step because the official procedure is a pair of pipelines. Every
executable inside the shell is absolute; the outer invocation still resolves
@sudo@ through 'HostTool'. Re-running it replaces the same keyring/list files.
-}
repositorySetupScript :: String
repositorySetupScript =
    "set -eu; "
        ++ "/usr/bin/curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey "
        ++ "| /usr/bin/gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg; "
        ++ "/usr/bin/curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list "
        ++ "| /usr/bin/sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' "
        ++ "> /etc/apt/sources.list.d/nvidia-container-toolkit.list"
