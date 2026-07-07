-- | Pure WSL2 provider argv builders and readiness classification.
module HostBootstrap.Wsl2
  ( Wsl2Readiness (..),
    Wsl2VM (..),
    bcdeditHypervisorLaunchArgs,
    classifyWsl2Readiness,
    normalizeWslText,
    wslListDistros,
    wslDistroStates,
    wslRunningDistros,
    wslReportsNoInstalledDistributions,
    wslReportsVirtualizationDisabled,
    wslInstallArgs,
    wslImportArgs,
    wslExecArgs,
    wslTerminateArgs,
    wslUnregisterArgs,
    wslShutdownArgs,
    mergeWslConfig,
  )
where

import Data.Char (isSpace, toLower)
import Data.List (isInfixOf, isPrefixOf)
import System.Exit (ExitCode (..))

newtype Wsl2VM = Wsl2VM {wsl2Distro :: String}
  deriving (Eq, Show)

data Wsl2Readiness = Ready | NeedsReboot | Unsatisfiable
  deriving (Eq, Show)

classifyWsl2Readiness :: (ExitCode, String, String) -> Wsl2Readiness
classifyWsl2Readiness result@(ExitSuccess, _, _)
  | wslReportsVirtualizationDisabled result = Unsatisfiable
  | otherwise = Ready
classifyWsl2Readiness (ExitFailure _, out, err)
  | "has no installed distributions" `isInfixOf` text = Ready
  | "reboot" `isInfixOf` text || "restart" `isInfixOf` text = NeedsReboot
  | "virtualization is not enabled" `isInfixOf` text = Unsatisfiable
  | otherwise = Unsatisfiable
  where
    text = normalizeWslText (out ++ "\n" ++ err)

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

wslImportArgs :: String -> FilePath -> FilePath -> [String]
wslImportArgs distro installDir tarball =
  ["--import", distro, installDir, tarball, "--version", "2"]

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

-- | Merge the demo-managed @.wslconfig@ body (as
-- 'HostBootstrap.Cluster.Cordon.wsl2SizingArgs' emits — now @[general]@ +
-- @[wsl2]@) into an existing @.wslconfig@, **preserving every other section** the
-- user set. The managed sections are exactly those the @body@ declares, so the
-- merge drops each old managed section (its header and keys up to the next section
-- header) and appends the new body; a user's @[experimental]@ / @[user]@ /
-- @[network]@ blocks survive untouched. The @.wslconfig@ is a /global/ user file,
-- so the whole file is backed up on first write and restored on teardown. Pure, so
-- the never-clobber-other-sections merge is unit-tested. Idempotent: re-merging a
-- body into a file that already carries our sections replaces them in place.
mergeWslConfig :: String -> [String] -> String
mergeWslConfig existing body =
  let managed = [sectionName l | l <- body, isSectionHeader l]
      kept = dropManaged managed (lines existing)
      keptTrimmed = reverse (dropWhile blank (reverse kept))
      separator = if null keptTrimmed then [] else keptTrimmed ++ [""]
   in unlines (separator ++ body)
  where
    blank = all isSpace
    dropManaged managed = go
      where
        go [] = []
        go (l : ls)
          | isSectionHeader l && sectionName l `elem` managed =
              go (dropWhile (not . isSectionHeader) ls)
          | otherwise = l : go ls
    isSectionHeader s = case trim s of
      ('[' : rest) -> not (null rest) && last (trim s) == ']'
      _ -> False
    sectionName s = map toLower (takeWhile (/= ']') (drop 1 (trim s)))
    trim = dropWhile isSpace
