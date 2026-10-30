{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}

-- | The @ensure wsl2@ reconciler: the Windows VM-provider substrate.
module HostBootstrap.Ensure.Wsl2 (
    reconciler,
    installSteps,
    WslPlatformStatus (..),
    classifyWslStatus,
    WslAction (..),
    wslNextAction,
    wsl2Ready,
    bcdeditHypervisorLaunchArgs,
    normalizeWslText,
    wslReportsNoInstalledDistributions,
    wslReportsVirtualizationDisabled,
)
where

import Data.List (isInfixOf)
import Foreign.C.Types (CInt (..))
import HostBootstrap.Ensure (
    FramePlan (InstallHere),
    InstallStep (..),
    Reconciler (..),
    StepOutcome (..),
    classifyStepOutcome,
    frameTable,
    installAndVerify,
    normalizeWslText,
    reconcilerInstallSteps,
    runTool,
    windowsRow,
 )
import HostBootstrap.HostConfig (HostConfig (hcSubstrate), buildHostConfig)
import HostBootstrap.HostTool (HostTool (Bcdedit, Winget, Wsl), toolCommandName)
import HostBootstrap.Substrate (Substrate)
import System.Exit (ExitCode (ExitSuccess), die)
#ifdef mingw32_HOST_OS
import System.Win32.Info.Computer (ProcessorFeature, isProcessorFeaturePresent)
#endif

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

-- | What the captured platform status establishes, independently of a distro.
data WslPlatformStatus
    = WslPlatformReady
    | WslVirtualizationUnavailable
    | WslPlatformAbsent
    deriving (Eq, Show)

{- | Classify only @wsl --status@. Virtualization diagnostics take precedence
over success and no-distribution text; a platform with no installed distro is
otherwise ready. An unrunnable command or other non-zero result is absent.
-}
classifyWslStatus :: Either String (ExitCode, String, String) -> WslPlatformStatus
classifyWslStatus result = case result of
    Left _ -> WslPlatformAbsent
    Right status@(code, _, _)
        | wslReportsVirtualizationDisabled status -> WslVirtualizationUnavailable
        | code == ExitSuccess || wslReportsNoInstalledDistributions status -> WslPlatformReady
        | otherwise -> WslPlatformAbsent

-- | The next prerequisite action selected from the platform observations.
data WslAction
    = WslSetDefaultVersion InstallStep
    | WslInstallPlatform
    | WslEnableHypervisorLaunch
    | WslFirmwareUnavailable
    deriving (Eq, Show)

{- | Choose from status, hypervisor presence, and OS-reported firmware
availability. Ready ignores both machine facts; a present hypervisor ignores
the firmware flag.
-}
wslNextAction :: WslPlatformStatus -> Bool -> Bool -> WslAction
wslNextAction status hypervisor firmware = case status of
    WslPlatformReady -> WslSetDefaultVersion defaultVersionStep
    WslPlatformAbsent
        | hypervisor || firmware -> WslInstallPlatform
        | otherwise -> WslFirmwareUnavailable
    WslVirtualizationUnavailable
        | hypervisor -> WslInstallPlatform
        | firmware -> WslEnableHypervisorLaunch
        | otherwise -> WslFirmwareUnavailable

defaultVersionStep :: InstallStep
defaultVersionStep = InstallStep Wsl ["--set-default-version", "2"]

bcdeditHypervisorLaunchArgs :: [String]
bcdeditHypervisorLaunchArgs = ["/set", "hypervisorlaunchtype", "auto"]

reconciler :: Reconciler
reconciler =
    Reconciler
        { reconcilerName = "wsl2"
        , reconcilerSummary = "Ensure the WSL2 Ubuntu-24.04 host-provider is available"
        , -- One row. The accelerator makes no difference to installing WSL2, so the
          -- row does not name it.
          reconcilerFrames =
            frameTable
                [ windowsRow
                    ( InstallHere
                        [ InstallStep Winget ["install", "--id", "Microsoft.WSL", "--exact", "--accept-package-agreements", "--accept-source-agreements"]
                        , InstallStep Wsl ["--install", "--no-distribution"]
                        , defaultVersionStep
                        ]
                    )
                ]
        , reconcile = reconcileWsl2
        }

-- | Observe platform readiness from one status result, without an online query.
wsl2Ready :: HostConfig -> IO Bool
wsl2Ready cfg = do
    result <- runTool cfg Wsl ["--status"]
    pure (classifyWslStatus result == WslPlatformReady)

reconcileWsl2 :: HostConfig -> IO ()
reconcileWsl2 cfg = do
    status <- classifyWslStatus <$> runTool cfg Wsl ["--status"]
    action <- case status of
        WslPlatformReady -> pure (wslNextAction status False False)
        _ -> do
            hypervisor <- readHypervisorPresent >>= requireObservation
            if hypervisor
                then pure (wslNextAction status True False)
                else do
                    firmware <- readFirmwareVirtualization >>= requireObservation
                    pure (wslNextAction status False firmware)
    runAction cfg action
  where
    requireObservation = either (die . ("ensure wsl2: " ++)) pure

    runAction currentHostConfig (WslSetDefaultVersion (InstallStep tool args)) = do
        result <- runTool currentHostConfig tool args
        case classifyStepOutcome tool args result of
            StepContinue -> reportReady
            StepAlreadyInstalled -> reportReady
            StepRebootRequired ->
                die "ensure wsl2: host reboot required after WSL2 install; reboot and retry"
            StepFailed reason -> die ("ensure wsl2: " ++ reason)
    runAction currentHostConfig WslInstallPlatform = do
        installAndVerify "wsl2" wsl2Ready installSteps currentHostConfig
        refreshed <- buildHostConfig (hcSubstrate currentHostConfig)
        runAction refreshed (WslSetDefaultVersion defaultVersionStep)
    runAction currentHostConfig WslEnableHypervisorLaunch = setHypervisorLaunch currentHostConfig
    runAction _ WslFirmwareUnavailable =
        die "ensure wsl2: Windows reports firmware virtualization as unavailable; check BIOS/UEFI virtualization and host configuration, then retry"

    reportReady = putStrLn "ensure wsl2: platform ready; default version is 2"

foreign import ccall unsafe "hostbootstrap_wsl_hypervisor_present"
    c_wslHypervisorPresent :: IO CInt

readHypervisorPresent :: IO (Either String Bool)
readHypervisorPresent = do
    observed <- c_wslHypervisorPresent
    pure $ case observed of
        0 -> Right False
        1 -> Right True
        _ -> Left "WSL hypervisor observation requires a Windows x86 processor with CPUID leaf 1"

{- | Feature 21 reports firmware virtualization made available by the OS. A
false result does not by itself identify a disabled BIOS/UEFI setting.
-}
readFirmwareVirtualization :: IO (Either String Bool)
#ifdef mingw32_HOST_OS
readFirmwareVirtualization = Right <$> isProcessorFeaturePresent firmwareVirtualizationFeature

firmwareVirtualizationFeature :: ProcessorFeature
firmwareVirtualizationFeature = 21
#else
readFirmwareVirtualization = pure (Left "WSL firmware virtualization observation requires Windows")
#endif

setHypervisorLaunch :: HostConfig -> IO ()
setHypervisorLaunch cfg = do
    result <- runTool cfg Bcdedit bcdeditHypervisorLaunchArgs
    case result of
        Right (ExitSuccess, _, _) ->
            die "ensure wsl2: host reboot required after WSL2 hypervisor launch configuration; reboot and retry"
        Right (_, _, errOut) ->
            die ("ensure wsl2: install step `" ++ toolCommandName Bcdedit ++ " " ++ unwords bcdeditHypervisorLaunchArgs ++ "` failed " ++ errOut)
        Left err -> die ("ensure wsl2: " ++ err)

installSteps :: Substrate -> Either String [InstallStep]
installSteps = reconcilerInstallSteps reconciler
