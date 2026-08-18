-- | The @ensure wsl2@ reconciler: the Windows VM-provider substrate.
module HostBootstrap.Ensure.Wsl2
  ( reconciler,
    installSteps,
    powerShellBoolArgs,
    wsl2Ready,
    bcdeditHypervisorLaunchArgs,
    normalizeWslText,
    wslReportsNoInstalledDistributions,
    wslReportsVirtualizationDisabled,
  )
where

import Data.Char (toLower)
import Data.List (isInfixOf)
import HostBootstrap.Ensure
  ( FramePlan (InstallHere),
    InstallStep (..),
    Reconciler (..),
    frameTable,
    installAndVerify,
    reconcilerInstallSteps,
    runTool,
    windowsRow,
  )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Bcdedit, PowerShell, Winget, Wsl), toolCommandName)
import HostBootstrap.Substrate (Substrate)
import System.Exit (ExitCode (ExitSuccess), die)

wslReportsVirtualizationDisabled :: (ExitCode, String, String) -> Bool
wslReportsVirtualizationDisabled (_, out, err) =
  "virtualization is not enabled" `isInfixOf` text
    || "wsl2 is unable to start" `isInfixOf` text
  where
    text = normalizeWslText (out ++ "\n" ++ err)

wslReportsNoInstalledDistributions :: (ExitCode, String, String) -> Bool
wslReportsNoInstalledDistributions (_, out, err) =
  "has no installed distributions"
    `isInfixOf` normalizeWslText (out ++ "\n" ++ err)

normalizeWslText :: String -> String
normalizeWslText = map toLower . filter (/= '\0')

bcdeditHypervisorLaunchArgs :: [String]
bcdeditHypervisorLaunchArgs = ["/set", "hypervisorlaunchtype", "auto"]

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "wsl2",
      reconcilerSummary = "Ensure the WSL2 Ubuntu-24.04 host-provider is available",
      -- One row. The accelerator makes no difference to installing WSL2, so the
      -- row does not name it.
      reconcilerFrames =
        frameTable
          [ windowsRow
              ( InstallHere
                  [ InstallStep Winget ["install", "--id", "Microsoft.WSL", "--exact", "--accept-package-agreements", "--accept-source-agreements"],
                    InstallStep Wsl ["--install", "--no-distribution"],
                    InstallStep Wsl ["--set-default-version", "2"]
                  ]
              )
          ],
      reconcile = reconcileWsl2
    }

wsl2Ready :: HostConfig -> IO Bool
wsl2Ready cfg = do
  result <- runTool cfg Wsl ["--status"]
  case result of
    Right status@(ExitSuccess, _, _) ->
      pure (not (wslReportsVirtualizationDisabled status))
    Right status
      | wslReportsNoInstalledDistributions status ->
          pure True
    _ -> wsl2OnlineListReady cfg

wsl2OnlineListReady :: HostConfig -> IO Bool
wsl2OnlineListReady cfg = do
  result <- runTool cfg Wsl ["--list", "--online"]
  pure $ case result of
    Right online@(ExitSuccess, out, err) ->
      not (wslReportsVirtualizationDisabled online)
        && "ubuntu-24.04" `elem` words (normalizeWslText (out ++ "\n" ++ err))
    _ -> False

reconcileWsl2 :: HostConfig -> IO ()
reconcileWsl2 cfg = do
  satisfied <- wsl2Ready cfg
  if satisfied
    then putStrLn "ensure wsl2: present (no-op)"
    else reconcileHypervisorLaunch cfg

reconcileHypervisorLaunch :: HostConfig -> IO ()
reconcileHypervisorLaunch cfg = do
  firmware <- runPowerShellBool cfg "(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty VirtualizationFirmwareEnabled)"
  case firmware of
    Right False ->
      die "ensure wsl2: firmware virtualization is disabled; enable virtualization in BIOS/UEFI and retry"
    Left err -> die ("ensure wsl2: " ++ err)
    Right True -> do
      hypervisor <- runPowerShellBool cfg "(Get-ComputerInfo -Property HyperVisorPresent).HyperVisorPresent"
      case hypervisor of
        Right True -> installAndVerify "wsl2" wsl2Ready installSteps cfg
        Right False -> setHypervisorLaunch cfg
        Left err -> die ("ensure wsl2: " ++ err)

setHypervisorLaunch :: HostConfig -> IO ()
setHypervisorLaunch cfg = do
  result <- runTool cfg Bcdedit bcdeditHypervisorLaunchArgs
  case result of
    Right (ExitSuccess, _, _) ->
      die "ensure wsl2: host reboot required after WSL2 hypervisor launch configuration; reboot and retry"
    Right (_, _, errOut) ->
      die ("ensure wsl2: install step `" ++ toolCommandName Bcdedit ++ " " ++ unwords bcdeditHypervisorLaunchArgs ++ "` failed " ++ errOut)
    Left err -> die ("ensure wsl2: " ++ err)

runPowerShellBool :: HostConfig -> String -> IO (Either String Bool)
runPowerShellBool cfg expr = do
  result <- runTool cfg PowerShell (powerShellBoolArgs expr)
  pure $ case result of
    Right (ExitSuccess, out, _) -> parsePowerShellBool expr out
    Right (_, _, errOut) -> Left ("powershell probe failed for " ++ expr ++ ": " ++ errOut)
    Left err -> Left err

powerShellBoolArgs :: String -> [String]
powerShellBoolArgs expr =
  ["-NoProfile", "-Command", expr]

parsePowerShellBool :: String -> String -> Either String Bool
parsePowerShellBool expr out =
  case map toLower (trim out) of
    "true" -> Right True
    "false" -> Right False
    other -> Left ("could not parse boolean powershell output for " ++ expr ++ ": " ++ other)
  where
    trim =
      reverse
        . dropWhile (`elem` [' ', '\r', '\n', '\t'])
        . reverse
        . dropWhile (`elem` [' ', '\r', '\n', '\t'])

installSteps :: Substrate -> Either String [InstallStep]
installSteps = reconcilerInstallSteps reconciler
