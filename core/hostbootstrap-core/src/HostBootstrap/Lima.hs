{- | Lima VM lifecycle argv builders.

On Apple Silicon the demo's fresh Linux host is a Lima VM. These builders
keep the provider-specific command shape pure and unit-testable; callers run
the argv through resolved 'HostTool' values.
-}
module HostBootstrap.Lima (
    LimaVM (..),
    startVMArgs,
    writableMountArgs,
    stopVMArgs,
    shellVMArgs,
    copyToVMArgs,
    statusVMArgs,
    deleteVMArgs,
)
where

import HostBootstrap.Lift.Context (LimaVM (..), shellVMArgs)
import HostBootstrap.Substrate.Frame (FrameNoun (LimaInstance), guardedDeleteArgs)

-- | Start a named Ubuntu 24.04 Lima VM sized to the project budget.
startVMArgs :: LimaVM -> [String] -> [String]
startVMArgs vm sizing =
    ["start", "-y", "--timeout", "15m", "--name=" ++ limaName vm, "--containerd", "none"] ++ sizing ++ ["template:ubuntu-24.04"]

{- | Mount exactly one host directory into a newly created Lima instance with
write access. @--mount-only@ replaces Lima's default read-only host-home mount,
so a project path below that home does not overlap an existing mount and no
unrelated host directory becomes writable.
-}
writableMountArgs :: FilePath -> [String]
writableMountArgs source = ["--mount-only", source ++ ":w"]

-- | Stop a named Lima instance without deleting it — the @project down@
-- teardown stops the VM (it does not destroy it; that is @project destroy@).
stopVMArgs :: LimaVM -> [String]
stopVMArgs vm = ["stop", limaName vm]

-- | Copy a host file into the Lima VM.
copyToVMArgs :: LimaVM -> FilePath -> FilePath -> [String]
copyToVMArgs vm src dst = ["copy", src, limaName vm ++ ":" ++ dst]

-- | Query a named Lima instance.
statusVMArgs :: LimaVM -> [String]
statusVMArgs vm = ["list", "--format", "json", limaName vm]

{- | This frame's row in the one guarded destructive delete (§ LL): the noun the
refusal reads in, and the argv for a name the guard has already admitted.
-}
deleteVMArgs :: String -> LimaVM -> Either String [String]
deleteVMArgs prefix vm =
    guardedDeleteArgs LimaInstance prefix (limaName vm) $
        \name -> ["delete", name, "--force"]
