-- | The incus VM lifecycle: pure argument builders, the name-prefix delete-guard,
-- and the reboot-to-ready classification.
--
-- @incus@ is the host-provider axis (see @development_plan_standards.md § U@): a
-- target linux host is either the local host or an incus VM. Every VM operation
-- goes through the single resolved host @incus@ (the in-VM tools are the VM's own
-- @$PATH@ binaries reached through one @incus exec@). The argv builders and the
-- 'classifyDockerReadiness' decision are pure so they are unit-tested; the IO
-- dispatch lives in "HostBootstrap.HostTarget".
module HostBootstrap.Incus
  ( IncusVM (..),
    DockerReadiness (..),
    createVMArgs,
    startVMArgs,
    stopVMArgs,
    execVMArgs,
    pushFileArgs,
    rebootVMArgs,
    destroyVMArgs,
    classifyDockerReadiness,
  )
where

import Data.List (isInfixOf, isPrefixOf)
import System.Exit (ExitCode (..))

-- | An incus VM: its name and the image it launches from
-- (e.g. @"images:ubuntu/24.04"@).
data IncusVM = IncusVM
  { vmName :: String,
    vmImage :: String
  }
  deriving (Eq, Show)

-- | @incus launch <image> <name> --vm [sizing...]@ — create + start a VM, sized
-- by the budget args ('HostBootstrap.Cluster.Cordon.incusSizingArgs').
createVMArgs :: IncusVM -> [String] -> [String]
createVMArgs vm sizing = ["launch", vmImage vm, vmName vm, "--vm"] ++ sizing

-- | @incus start <name>@.
startVMArgs :: IncusVM -> [String]
startVMArgs vm = ["start", vmName vm]

-- | @incus stop <name>@.
stopVMArgs :: IncusVM -> [String]
stopVMArgs vm = ["stop", vmName vm]

-- | @incus exec <name> -- <cmd...>@ — the single host dispatch into the VM. The
-- @<cmd>@ is the VM's own @$PATH@ binary (§ K governs host invocation only).
execVMArgs :: IncusVM -> [String] -> [String]
execVMArgs vm cmd = ["exec", vmName vm, "--"] ++ cmd

-- | @incus file push <src> <name>/<dst>@.
pushFileArgs :: IncusVM -> FilePath -> FilePath -> [String]
pushFileArgs vm src dst = ["file", "push", src, vmName vm ++ dst]

-- | @incus restart <name>@ — reboot the guest.
rebootVMArgs :: IncusVM -> [String]
rebootVMArgs vm = ["restart", vmName vm]

-- | The name-prefix delete-guard (the same idiom as the harness
-- 'HostBootstrap.Harness.guardTestDelete'): @incus delete <name> --force@ is
-- refused unless the VM name carries the guard prefix, so a destroy can never
-- remove a VM outside the managed namespace.
destroyVMArgs :: String -> IncusVM -> Either String [String]
destroyVMArgs prefix vm
  | prefix `isPrefixOf` vmName vm = Right ["delete", vmName vm, "--force"]
  | otherwise =
      Left
        ( "refusing to delete incus VM not carrying the guard prefix '"
            ++ prefix
            ++ "': "
            ++ vmName vm
        )

-- | The reboot-to-ready classification of a @docker info@ probe inside a fresh
-- VM.
data DockerReadiness = Ready | NeedsReboot | Unsatisfiable
  deriving (Eq, Show)

-- | Classify a @docker info@ probe @(exit, stdout, stderr)@: success is 'Ready';
-- a permission/group failure (Docker installed but the socket needs a reboot or
-- re-login to take effect) is 'NeedsReboot'; anything else is 'Unsatisfiable'.
-- Pure.
classifyDockerReadiness :: (ExitCode, String, String) -> DockerReadiness
classifyDockerReadiness (ExitSuccess, _, _) = Ready
classifyDockerReadiness (ExitFailure _, out, err) =
  let s = out ++ "\n" ++ err
   in if any (`isInfixOf` s) needsRebootMarkers
        then NeedsReboot
        else Unsatisfiable
  where
    needsRebootMarkers =
      [ "permission denied",
        "Got permission denied",
        "newgrp",
        "docker group",
        "the docker group"
      ]
