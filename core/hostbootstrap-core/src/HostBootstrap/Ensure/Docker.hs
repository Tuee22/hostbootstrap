-- | The @ensure docker@ reconciler: a reachable Docker daemon on every substrate.
--
-- Install-and-verify (see @development_plan_standards.md § L@): on Linux,
-- @apt-get install docker.io@ and enable the daemon if @docker info@ is not
-- reachable, a verified no-op when it is. On Apple silicon Docker is provided by
-- the per-project Colima VM, so the planner defers to @ensure colima@ rather than
-- attempting a host-package install. The pure 'installSteps' planner is
-- unit-tested.
module HostBootstrap.Ensure.Docker (reconciler, installSteps) where

import HostBootstrap.Ensure
  ( InstallStep (..),
    Reconciler (..),
    installAndVerify,
    runTool,
  )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Docker, Sudo))
import HostBootstrap.Substrate
  ( Substrate,
    SubstrateName (AppleSilicon, LinuxCpu, LinuxGpu),
    substrateName,
  )
import System.Exit (ExitCode (..))

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "docker",
      reconcilerSummary = "Ensure the Docker daemon is installed and reachable",
      appliesTo = const True,
      requirement = "all substrates",
      reconcile = installAndVerify "docker" satisfied installSteps
    }

-- | Docker is satisfied when @docker info@ exits zero (the daemon is reachable).
satisfied :: HostConfig -> IO Bool
satisfied cfg = do
  result <- runTool cfg Docker ["info"]
  pure $ case result of
    Right (ExitSuccess, _, _) -> True
    _ -> False

-- | The substrate-branched install plan. On Linux, @apt-get install docker.io@
-- and enable the daemon. On Apple silicon, Docker is the per-project Colima VM's
-- responsibility, so defer to @ensure colima@.
installSteps :: Substrate -> Either String [InstallStep]
installSteps sub = case substrateName sub of
  AppleSilicon ->
    Left "on Apple silicon Docker is provided by the per-project Colima VM; run `ensure colima` first"
  LinuxCpu -> Right linuxSteps
  LinuxGpu -> Right linuxSteps
  where
    linuxSteps =
      [ InstallStep Sudo ["apt-get", "install", "-y", "docker.io"],
        InstallStep Sudo ["systemctl", "enable", "--now", "docker"]
      ]
