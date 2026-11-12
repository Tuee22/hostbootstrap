{- | Incus target data, the shared crossing renderer, and file transfer.

Provider lifecycle commands are described once in
"HostBootstrap.Substrate.Provider.Command". The lower lift context owns the
target and crossing renderer; staging uses the file-push arguments here.
-}
module HostBootstrap.Incus (
    IncusVM (..),
    execVMArgs,
    pushFileArgs,
)
where

import HostBootstrap.Lift.Context (IncusVM (..), execVMArgs)

-- | @incus file push <src> <name>/<dst>@.
pushFileArgs :: IncusVM -> FilePath -> FilePath -> [String]
pushFileArgs vm src dst = ["file", "push", src, vmName vm ++ dst]
