{- | The Incus VM lifecycle: pure argument builders and the name-prefix
delete-guard.

@incus@ is the host-provider axis (see @development_plan_standards.md § U@).
Every VM operation goes through the single resolved host @incus@ (the in-VM
tools are the VM's own @$PATH@ binaries reached through one @incus exec@). The
argv builders are pure so they are unit-tested; the common substrate-provider
layer composes them with the generic frame fold in "HostBootstrap.Lift".
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

import HostBootstrap.Lift.Context (IncusVM (..), execVMArgs)
import HostBootstrap.Substrate.Frame (FrameNoun (IncusInstance), guardedDeleteArgs)

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

{- | This frame's row in the one guarded destructive delete (§ LL). The guard is
what keeps @incus delete \<name\> --force@ inside the managed namespace; this
module supplies only the noun and the argv.
-}
destroyVMArgs :: String -> IncusVM -> Either String [String]
destroyVMArgs prefix vm =
    guardedDeleteArgs IncusInstance prefix (vmName vm) $
        \name -> ["delete", name, "--force"]
