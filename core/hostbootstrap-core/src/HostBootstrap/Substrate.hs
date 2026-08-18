-- | Outer-host realization detection.
--
-- These tags describe the host detected at runtime so provider code can realize
-- the universal linux-cpu project substrate. They are provider-dispatch facts,
-- not competing project-visible execution contracts; projects do not declare a
-- host matrix in Python-owned config.
-- The classification core ('classify', 'parseDockerArch') is pure; 'detect'
-- wraps it with the platform reads and NVIDIA probe. Ported from the Python
-- @hostbootstrap/substrate.py@.
module HostBootstrap.Substrate
  ( SubstrateName (..),
    Arch (..),
    Substrate (..),
    renderSubstrateName,
    renderArch,
    HostFrame (..),
    allHostFrames,
    substrateFrame,
    renderHostFrame,
    isAppleSilicon,
    isLinux,
    isWindows,
    hasGpu,
    parseDockerArch,
    classify,
    detect,
    hasNvidiaGpu,
  )
where

import Data.Char (toLower)
import Data.List (isInfixOf)
import HostBootstrap.Effect.Run (CapturedRun (capturedExit, capturedStdout), runCaptured)
import System.Directory (doesPathExist, findExecutable)
import System.Exit (ExitCode (..))
import qualified System.Info as Info

-- | The supported outer-host realization tags.
data SubstrateName = AppleSilicon | LinuxCpu | LinuxGpu | WindowsCpu | WindowsGpu
  deriving (Eq, Show)

-- | Docker-style architecture.
data Arch = Amd64 | Arm64
  deriving (Eq, Show)

-- | A detected outer host paired with its Docker-style architecture. For
-- @apple-silicon@ the architecture is always 'Arm64'.
data Substrate = Substrate
  { substrateName :: SubstrateName,
    substrateArch :: Arch
  }
  deriving (Eq, Show)

renderSubstrateName :: SubstrateName -> String
renderSubstrateName AppleSilicon = "apple-silicon"
renderSubstrateName LinuxCpu = "linux-cpu"
renderSubstrateName LinuxGpu = "linux-gpu"
renderSubstrateName WindowsCpu = "windows-cpu"
renderSubstrateName WindowsGpu = "windows-gpu"

renderArch :: Arch -> String
renderArch Amd64 = "amd64"
renderArch Arm64 = "arm64"

-- | The closed set of outer-host frames a behaviour is written once per
-- (@development_plan_standards.md § LL@).
--
-- Three, not five. The accelerator is a capability /of/ a frame rather than a
-- frame of its own: the package manager, the host provider, and the ownership
-- primitive are the same on @linux-cpu@ and @linux-gpu@, and re-spelling that
-- pair at every site that routes on the host is how a new substrate constructor
-- silently misses a case that reads as exhaustive. A behaviour that genuinely
-- differs by accelerator says so by /requiring/ one, not by naming two tags.
data HostFrame
  = LinuxFrame
  | AppleFrame
  | WindowsFrame
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Every frame, for a total table.
allHostFrames :: [HostFrame]
allHostFrames = [minBound .. maxBound]

-- | The frame an outer host realizes.
--
-- This is the one place the five classification tags collapse to the three
-- frames, which is what makes 'isLinux', 'isWindows' and 'isAppleSilicon' one
-- derived fact rather than three independently maintained ones.
substrateFrame :: Substrate -> HostFrame
substrateFrame sub = case substrateName sub of
  AppleSilicon -> AppleFrame
  LinuxCpu -> LinuxFrame
  LinuxGpu -> LinuxFrame
  WindowsCpu -> WindowsFrame
  WindowsGpu -> WindowsFrame

renderHostFrame :: HostFrame -> String
renderHostFrame LinuxFrame = "linux"
renderHostFrame AppleFrame = "apple-silicon"
renderHostFrame WindowsFrame = "windows"

isAppleSilicon :: Substrate -> Bool
isAppleSilicon = (== AppleFrame) . substrateFrame

isLinux :: Substrate -> Bool
isLinux = (== LinuxFrame) . substrateFrame

isWindows :: Substrate -> Bool
isWindows = (== WindowsFrame) . substrateFrame

hasGpu :: Substrate -> Bool
hasGpu s = substrateName s `elem` [LinuxGpu, WindowsGpu]

-- | Map a host machine string (e.g. from @uname -m@ / 'System.Info.arch') to a
-- Docker-style architecture. Pure.
parseDockerArch :: String -> Either String Arch
parseDockerArch raw = case map toLower raw of
  "x86_64" -> Right Amd64
  "amd64" -> Right Amd64
  "aarch64" -> Right Arm64
  "arm64" -> Right Arm64
  other -> Left ("unsupported host architecture: " ++ other)

-- | The pure classification core: given the OS string ('System.Info.os'), the
-- raw machine architecture, and whether an NVIDIA GPU is present, return the
-- outer-host realization. Mirrors the branch structure of the Python @detect@.
classify :: String -> String -> Bool -> Either String Substrate
classify osName rawArch gpu = do
  arch <- parseDockerArch rawArch
  case map toLower osName of
    "darwin" ->
      if arch == Arm64
        then Right (Substrate AppleSilicon Arm64)
        else
          Left
            ( "hostbootstrap only supports Apple Silicon (arm64) on macOS; detected arch="
                ++ renderArch arch
            )
    "linux" ->
      Right (Substrate (if gpu then LinuxGpu else LinuxCpu) arch)
    "mingw32" ->
      Right (Substrate (if gpu then WindowsGpu else WindowsCpu) arch)
    other -> Left ("unsupported host platform: " ++ other)

-- | Detect the outer-host realization by reading the platform and probing for
-- an NVIDIA GPU.
detect :: IO (Either String Substrate)
detect = do
  gpu <- hasNvidiaGpu
  pure (classify Info.os Info.arch gpu)

-- | Whether the host has an NVIDIA GPU: the kernel markers, then @nvidia-smi -L@.
hasNvidiaGpu :: IO Bool
hasNvidiaGpu = do
  markers <- mapM doesPathExist ["/proc/driver/nvidia/version", "/dev/nvidiactl"]
  if or markers
    then pure True
    else do
      mSmi <- findExecutable "nvidia-smi"
      case mSmi of
        Nothing -> pure False
        Just smi -> do
          outcome <- runCaptured smi ["-L"] ""
          pure $ case outcome of
            Right run | capturedExit run == ExitSuccess -> "GPU" `isInfixOf` capturedStdout run
            _ -> False
