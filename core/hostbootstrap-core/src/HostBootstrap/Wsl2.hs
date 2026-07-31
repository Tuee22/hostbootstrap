-- | Pure WSL2 provider argv builders and output classification helpers.
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
import Data.List (isInfixOf, isPrefixOf)
import System.Exit (ExitCode (..))

newtype Wsl2VM = Wsl2VM {wsl2Distro :: String}
  deriving (Eq, Show)

wslReportsVirtualizationDisabled :: (ExitCode, String, String) -> Bool
wslReportsVirtualizationDisabled (_, out, err) =
  "virtualization is not enabled" `isInfixOf` text
    || "wsl2 is unable to start" `isInfixOf` text
  where
    text = normalizeWslText (out ++ "\n" ++ err)

wslReportsNoInstalledDistributions :: (ExitCode, String, String) -> Bool
wslReportsNoInstalledDistributions (_, out, err) =
  "has no installed distributions" `isInfixOf` normalizeWslText (out ++ "\n" ++ err)

normalizeWslText :: String -> String
normalizeWslText =
  map toLower . filter (/= '\0')

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

bcdeditHypervisorLaunchArgs :: [String]
bcdeditHypervisorLaunchArgs =
  ["/set", "hypervisorlaunchtype", "auto"]

wslInstallArgs :: String -> String -> [String]
wslInstallArgs distro vhdSize =
  ["--install", "-d", "Ubuntu-24.04", "--name", distro, "--no-launch", "--vhd-size", vhdSize]

wslExecArgs :: String -> [String] -> [String]
wslExecArgs distro inner =
  ["-d", distro, "--"] ++ inner

wslTerminateArgs :: String -> [String]
wslTerminateArgs distro =
  ["--terminate", distro]

wslUnregisterArgs :: String -> String -> Either String [String]
wslUnregisterArgs prefix distro
  | prefix `isPrefixOf` distro = Right ["--unregister", distro]
  | otherwise =
      Left
        ( "refusing to unregister WSL2 distro not carrying the guard prefix '"
            ++ prefix
            ++ "': "
            ++ distro
        )

wslShutdownArgs :: [String]
wslShutdownArgs =
  ["--shutdown"]
