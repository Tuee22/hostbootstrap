-- | Pure WSL2 lifecycle builders. Prerequisite diagnostics are compatibility
-- reexports of the lower "HostBootstrap.Ensure.Wsl2" definitions.
module HostBootstrap.Wsl2
  ( Wsl2VM (..),
    bcdeditHypervisorLaunchArgs,
    normalizeWslText,
    wslListDistros,
    wslDistroStates,
    wslRunningDistros,
    wslReportsNoInstalledDistributions,
    wslReportsVirtualizationDisabled,
    wslInstallArgs,
    wslExecArgs,
    wslTerminateArgs,
    wslUnregisterArgs,
    wslShutdownArgs,
  )
where

import Data.Char (toLower)
import HostBootstrap.Ensure.Wsl2
  ( bcdeditHypervisorLaunchArgs,
    normalizeWslText,
    wslReportsNoInstalledDistributions,
    wslReportsVirtualizationDisabled,
  )
import HostBootstrap.Lift.Context (Wsl2VM (..), wslExecArgs)
import HostBootstrap.Substrate.Frame (FrameNoun (Wsl2Distribution), guardedDeleteArgs)

-- | Tokenise @wsl --list --quiet@ output into distro names for a membership
-- test. Strips the UTF-16 NUL padding and splits on whitespace, but preserves
-- case — WSL2 distro names are case-sensitive, unlike the lowercased marker
-- checks that go through 'normalizeWslText'.
wslListDistros :: String -> [String]
wslListDistros = words . filter (/= '\0')

{- | Parse @wsl --list --verbose@ into @(distro, lowercased-state)@ pairs: strip the
UTF-16 NUL padding, drop the leading @*@ default marker on each row, and skip the
@NAME/STATE/VERSION@ header. Distro names preserve case (WSL2 names are
case-sensitive); the state is lowercased for comparison. Pure, so it is unit-tested.
-}
wslDistroStates :: String -> [(String, String)]
wslDistroStates raw =
  [ (name, map toLower state)
  | line <- lines (filter (/= '\0') raw)
  , (name : state : _) <- [dropStar (words line)]
  , map toLower name /= "name"
  ]
  where
    dropStar ("*" : rest) = rest
    dropStar toks = toks

-- | The distro names reported RUNNING by @wsl --list --verbose@. Pure.
wslRunningDistros :: String -> [String]
wslRunningDistros = map fst . filter ((== "running") . snd) . wslDistroStates

wslInstallArgs :: String -> String -> [String]
wslInstallArgs distro vhdSize =
  ["--install", "-d", "Ubuntu-24.04", "--name", distro, "--no-launch", "--vhd-size", vhdSize]

wslTerminateArgs :: String -> [String]
wslTerminateArgs distro =
  ["--terminate", distro]

-- | This frame's row in the one guarded destructive delete (§ LL). WSL2 spells
-- the removal @--unregister@; the guard that decides whether it may happen is
-- the same computation Lima's and Incus's rows go through.
wslUnregisterArgs :: String -> String -> Either String [String]
wslUnregisterArgs prefix distro =
  guardedDeleteArgs Wsl2Distribution prefix distro $
    \name -> ["--unregister", name]

wslShutdownArgs :: [String]
wslShutdownArgs =
  ["--shutdown"]
