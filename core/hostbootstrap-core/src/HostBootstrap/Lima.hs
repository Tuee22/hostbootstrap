{- | Lima VM lifecycle argv builders.

On Apple Silicon the demo's fresh Linux host is a Lima VM. These builders
keep the provider-specific command shape pure and unit-testable; callers run
the argv through resolved 'HostTool' values.
-}
module HostBootstrap.Lima (
    LimaVM (..),
    startVMArgs,
    stopVMArgs,
    shellVMArgs,
    copyToVMArgs,
    statusVMArgs,
    deleteVMArgs,
)
where

import Data.List (isPrefixOf)

-- | A Lima-backed Linux VM, identified by its Lima instance name.
newtype LimaVM = LimaVM
    { limaName :: String
    }
    deriving (Eq, Show)

-- | Start a named Ubuntu 24.04 Lima VM sized to the project budget.
startVMArgs :: LimaVM -> [String] -> [String]
startVMArgs vm sizing =
    ["start", "-y", "--timeout", "15m", "--name=" ++ limaName vm, "--containerd", "none"] ++ sizing ++ ["template:ubuntu-24.04"]

-- | Stop a named Lima instance without deleting it — the @project down@
-- teardown stops the VM (it does not destroy it; that is @project destroy@).
stopVMArgs :: LimaVM -> [String]
stopVMArgs vm = ["stop", limaName vm]

-- | Execute a command inside the Lima VM as root.
--
-- Lima shells into the guest as the host user on current releases. The demo's
-- pristine Linux frame is rooted under @/root@, matching the Incus and WSL2
-- paths, so every provider lift enters the guest through passwordless sudo with
-- @HOME@ set to root's home.
shellVMArgs :: LimaVM -> [String] -> [String]
shellVMArgs vm cmd = ["shell", limaName vm, "--", "sudo", "-H"] ++ cmd

-- | Copy a host file into the Lima VM.
copyToVMArgs :: LimaVM -> FilePath -> FilePath -> [String]
copyToVMArgs vm src dst = ["copy", src, limaName vm ++ ":" ++ dst]

-- | Query a named Lima instance.
statusVMArgs :: LimaVM -> [String]
statusVMArgs vm = ["list", "--format", "json", limaName vm]

{- | Guarded destructive delete. The caller must supply the project guard
prefix; non-matching instance names refuse to produce argv.
-}
deleteVMArgs :: String -> LimaVM -> Either String [String]
deleteVMArgs prefix vm
    | prefix `isPrefixOf` limaName vm = Right ["delete", limaName vm, "--force"]
    | otherwise =
        Left
            ( "refusing to delete Lima VM not carrying the guard prefix '"
                ++ prefix
                ++ "': "
                ++ limaName vm
            )
