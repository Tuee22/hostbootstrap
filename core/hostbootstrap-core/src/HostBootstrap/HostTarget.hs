-- | The host-provider target axis: a linux host is either the local host or an
-- incus VM, dispatched through the single resolved host @incus@.
--
-- 'runInTarget' parameterizes every linux-host operation (build, ensure docker,
-- kind, harbor, run, the harness) by a 'HostTarget' with no per-call branching
-- (see @development_plan_standards.md § U@): @Local@ runs the resolved tool
-- directly; @InVM@ dispatches @incus exec <name> -- <tool> <args>@ into the VM,
-- where the in-VM tool is the VM's own @$PATH@ binary.
module HostBootstrap.HostTarget
  ( HostTarget (..),
    runInTarget,
    rebootDockerToReady,
  )
where

import Control.Monad (void)
import HostBootstrap.Ensure (runTool)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Incus), toolCommandName)
import HostBootstrap.Incus
  ( DockerReadiness (..),
    IncusVM,
    classifyDockerReadiness,
    execVMArgs,
    rebootVMArgs,
  )
import HostBootstrap.Readiness
  ( PollError (..),
    PollPolicy (..),
    ProbeResult (..),
    pollUntilReadyWith,
    seconds,
  )
import System.Exit (ExitCode)

-- | A deployment target: the local host, or inside a named incus VM.
data HostTarget = Local | InVM IncusVM
  deriving (Eq, Show)

-- | Run a resolved host tool against a target. @Local@ is 'runTool' directly;
-- @InVM@ dispatches through the host @incus exec@ — the only place the in-VM
-- tool is named bare (it is the VM's own @$PATH@ binary, a separate machine).
runInTarget ::
  HostConfig ->
  HostTarget ->
  HostTool ->
  [String] ->
  IO (Either String (ExitCode, String, String))
runInTarget cfg Local t args = runTool cfg t args
runInTarget cfg (InVM vm) t args =
  runTool cfg Incus (execVMArgs vm (toolCommandName t : args))

-- | Reboot-to-ready: probe @docker info@ in the VM; on 'NeedsReboot' run
-- @incus restart@ and retry, bounded by @maxReboots@; 'Ready' succeeds and
-- 'Unsatisfiable' fails fast. The classification is the pure
-- 'classifyDockerReadiness'; this loop is exercised live.
rebootDockerToReady :: HostConfig -> IncusVM -> Int -> IO (Either String ())
rebootDockerToReady cfg vm maxReboots = do
  -- @maxReboots@ reboots means @maxReboots + 1@ probes (the initial probe plus one
  -- after each reboot); the reboot is the between-attempt recovery, so the delay is 0.
  outcome <- pollUntilReadyWith (PollPolicy (maxReboots + 1) (seconds 0)) "reboot-to-ready" recover dockerProbe cfg
  pure $ case outcome of
    Right () -> Right ()
    Left (PollTimeout _) -> Left "docker did not become ready within the reboot budget"
    Left (PollFailed msg) -> Left msg
  where
    dockerProbe c = verdict <$> runTool c Incus (execVMArgs vm ["docker", "info"])
    verdict (Left err) = Failed err
    verdict (Right result) = case classifyDockerReadiness result of
      Ready -> ProbeReady ()
      NeedsReboot -> NotReady
      Unsatisfiable -> Failed "docker is not satisfiable in the VM (install failed)"
    recover c = void (runTool c Incus (rebootVMArgs vm))
