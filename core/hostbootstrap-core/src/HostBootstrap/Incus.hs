{- | The incus VM lifecycle: pure argument builders, the name-prefix delete-guard,
and the reboot-to-ready classification.

@incus@ is the host-provider axis (see @development_plan_standards.md § U@).
Every VM operation goes through the single resolved host @incus@ (the in-VM
tools are the VM's own @$PATH@ binaries reached through one @incus exec@). The
argv builders are pure so they are unit-tested; the IO dispatch is the
provider-backed frame fold in "HostBootstrap.Lift".
-}
module HostBootstrap.Incus (
    IncusVM (..),
    createVMArgs,
    startVMArgs,
    stopVMArgs,
    execVMArgs,
    pushFileArgs,
    deviceListArgs,
    addDiskDeviceArgs,
    destroyVMArgs,
)
where

import Data.List (isPrefixOf)

{- | An incus VM: its name and the image it launches from
(e.g. @"images:ubuntu/24.04"@).
-}
data IncusVM = IncusVM
    { vmName :: String
    , vmImage :: String
    }
    deriving (Eq, Show)

{- | @incus launch <image> <name> --vm [sizing...]@ — create + start a VM, sized
by the budget args ('HostBootstrap.Cluster.Cordon.incusSizingArgs').
-}
createVMArgs :: IncusVM -> [String] -> [String]
createVMArgs vm sizing = ["launch", vmImage vm, vmName vm, "--vm"] ++ sizing

-- | @incus start <name>@.
startVMArgs :: IncusVM -> [String]
startVMArgs vm = ["start", vmName vm]

-- | @incus stop <name>@.
stopVMArgs :: IncusVM -> [String]
stopVMArgs vm = ["stop", vmName vm]

{- | @incus exec <name> -- <cmd...>@ — the single host dispatch into the VM. The
@<cmd>@ is the VM's own @$PATH@ binary (§ K governs host invocation only).
-}
execVMArgs :: IncusVM -> [String] -> [String]
execVMArgs vm cmd = ["exec", vmName vm, "--"] ++ cmd

-- | @incus file push <src> <name>/<dst>@.
pushFileArgs :: IncusVM -> FilePath -> FilePath -> [String]
pushFileArgs vm src dst = ["file", "push", src, vmName vm ++ dst]

-- | List the device names configured on an instance.
deviceListArgs :: IncusVM -> [String]
deviceListArgs vm = ["config", "device", "list", vmName vm]

{- | Attach a host directory to an instance as a disk device. Incus mounts the
host @source@ at @target@ inside the VM; the caller guards this add with
'deviceListArgs' so reconciling an existing device is a no-op.
-}
addDiskDeviceArgs :: IncusVM -> String -> FilePath -> FilePath -> [String]
addDiskDeviceArgs vm device source target =
    [ "config"
    , "device"
    , "add"
    , vmName vm
    , device
    , "disk"
    , "source=" ++ source
    , "path=" ++ target
    ]

-- \| The name-prefix delete-guard used by the lifecycle ownership checks:
-- @incus delete <name> --force@ is
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
