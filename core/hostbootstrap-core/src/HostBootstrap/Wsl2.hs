{- | Pure WSL2 lifecycle builders. Prerequisite diagnostics are compatibility
reexports of the lower "HostBootstrap.Ensure.Wsl2" definitions.
-}
module HostBootstrap.Wsl2 (
    Wsl2VM (..),
    bcdeditHypervisorLaunchArgs,
    normalizeWslText,
    wslListDistros,
    wslReportsNoInstalledDistributions,
    wslReportsVirtualizationDisabled,
    wslInstallArgs,
    wslExecArgs,
    wslUnregisterArgs,
    wslShutdownArgs,
)
where

import HostBootstrap.Ensure.Wsl2 (
    bcdeditHypervisorLaunchArgs,
    normalizeWslText,
    wslReportsNoInstalledDistributions,
    wslReportsVirtualizationDisabled,
 )
import HostBootstrap.Lift.Context (Wsl2VM (..), wslExecArgs)
import HostBootstrap.Substrate.Frame (FrameNoun (Wsl2Distribution), guardedDeleteArgs)

{- | Tokenise @wsl --list --quiet@ output into distro names for a membership
test. Strips the UTF-16 NUL padding and splits on whitespace, but preserves
case — WSL2 distro names are case-sensitive, unlike the lowercased marker
checks that go through 'normalizeWslText'.
-}
wslListDistros :: String -> [String]
wslListDistros = words . filter (/= '\0')


wslInstallArgs :: String -> String -> [String]
wslInstallArgs distro vhdSize =
    ["--install", "-d", "Ubuntu-24.04", "--name", distro, "--no-launch", "--vhd-size", vhdSize]

{- | This frame's row in the one guarded destructive delete (§ LL). WSL2 spells
the removal @--unregister@; the guard that decides whether it may happen is
the same computation Lima's and Incus's rows go through.
-}
wslUnregisterArgs :: String -> String -> Either String [String]
wslUnregisterArgs prefix distro =
    guardedDeleteArgs Wsl2Distribution prefix distro $
        \name -> ["--unregister", name]

wslShutdownArgs :: [String]
wslShutdownArgs =
    ["--shutdown"]
