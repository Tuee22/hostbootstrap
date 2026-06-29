-- | The @ensure wsl2@ reconciler: the Windows VM-provider substrate.
module HostBootstrap.Ensure.Wsl2
  ( reconciler,
    installSteps,
    powerShellBoolArgs,
    wsl2Ready,
  )
where

import Data.Char (toLower)
import HostBootstrap.Ensure
  ( InstallStep (..),
    Reconciler (..),
    installAndVerify,
    runTool,
  )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Bcdedit, PowerShell, Winget, Wsl), toolCommandName)
import HostBootstrap.Substrate
  ( Substrate,
    SubstrateName (WindowsCpu, WindowsGpu),
    isWindows,
    renderSubstrateName,
    substrateName,
  )
import qualified HostBootstrap.Wsl2 as Wsl2
import System.Exit (ExitCode (ExitSuccess), die)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "wsl2",
      reconcilerSummary = "Ensure the WSL2 Ubuntu-24.04 host-provider is available",
      appliesTo = isWindows,
      requirement = "windows-cpu or windows-gpu",
      reconcile = reconcileWsl2
    }

wsl2Ready :: HostConfig -> IO Bool
wsl2Ready cfg = do
  result <- runTool cfg Wsl ["--status"]
  case result of
    Right status@(ExitSuccess, _, _) ->
      pure (not (Wsl2.wslReportsVirtualizationDisabled status))
    Right status
      | Wsl2.wslReportsNoInstalledDistributions status ->
          pure True
    _ -> wsl2OnlineListReady cfg

wsl2OnlineListReady :: HostConfig -> IO Bool
wsl2OnlineListReady cfg = do
  result <- runTool cfg Wsl ["--list", "--online"]
  pure $ case result of
    Right online@(ExitSuccess, out, err) ->
      not (Wsl2.wslReportsVirtualizationDisabled online)
        && "ubuntu-24.04" `elem` words (Wsl2.normalizeWslText (out ++ "\n" ++ err))
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
  result <- runTool cfg Bcdedit Wsl2.bcdeditHypervisorLaunchArgs
  case result of
    Right (ExitSuccess, _, _) ->
      die "ensure wsl2: host reboot required after WSL2 hypervisor launch configuration; reboot and retry"
    Right (_, _, errOut) ->
      die ("ensure wsl2: install step `" ++ toolCommandName Bcdedit ++ " " ++ unwords Wsl2.bcdeditHypervisorLaunchArgs ++ "` failed " ++ errOut)
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
installSteps sub = case substrateName sub of
  WindowsCpu -> Right windowsSteps
  WindowsGpu -> Right windowsSteps
  other -> Left ("wsl2 is only applicable on Windows, not " ++ renderSubstrateName other)
  where
    windowsSteps =
      [ InstallStep Winget ["install", "--id", "Microsoft.WSL", "--exact", "--accept-package-agreements", "--accept-source-agreements"],
        InstallStep Wsl ["--install", "--no-distribution"],
        InstallStep Wsl ["--set-default-version", "2"]
      ]
