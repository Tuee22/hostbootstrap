-- | Substrate detection.
--
-- Three frozen substrates — @apple-silicon@, @linux-cpu@, @linux-gpu@ — match
-- the hardware targets downstream projects declare in @hostbootstrap.dhall@.
-- The classification core ('classify', 'parseDockerArch') is pure; 'detect'
-- wraps it with the platform reads and NVIDIA probe. Ported from the Python
-- @python/hostbootstrap/substrate.py@.
module HostBootstrap.Substrate
  ( SubstrateName (..),
    Arch (..),
    Substrate (..),
    renderSubstrateName,
    renderArch,
    isAppleSilicon,
    isLinux,
    hasGpu,
    parseDockerArch,
    classify,
    detect,
    hasNvidiaGpu,
  )
where

import Control.Exception (SomeException)
import Control.Exception.Safe (try)
import Data.Char (toLower)
import Data.List (isInfixOf)
import System.Directory (doesPathExist, findExecutable)
import System.Exit (ExitCode (..))
import qualified System.Info as Info
import System.Process (readProcessWithExitCode)

-- | The three supported host substrates.
data SubstrateName = AppleSilicon | LinuxCpu | LinuxGpu
  deriving (Eq, Show)

-- | Docker-style architecture.
data Arch = Amd64 | Arm64
  deriving (Eq, Show)

-- | A detected host substrate paired with its Docker-style architecture. For
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

renderArch :: Arch -> String
renderArch Amd64 = "amd64"
renderArch Arm64 = "arm64"

isAppleSilicon :: Substrate -> Bool
isAppleSilicon = (== AppleSilicon) . substrateName

isLinux :: Substrate -> Bool
isLinux s = substrateName s `elem` [LinuxCpu, LinuxGpu]

hasGpu :: Substrate -> Bool
hasGpu = (== LinuxGpu) . substrateName

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
-- substrate. Mirrors the branch structure of the Python @detect@.
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
    other -> Left ("unsupported host platform: " ++ other)

-- | Detect the host substrate by reading the platform and probing for an NVIDIA
-- GPU.
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
          result <- try (readProcessWithExitCode smi ["-L"] "")
          pure $ case (result :: Either SomeException (ExitCode, String, String)) of
            Right (ExitSuccess, out, _) -> "GPU" `isInfixOf` out
            _ -> False
