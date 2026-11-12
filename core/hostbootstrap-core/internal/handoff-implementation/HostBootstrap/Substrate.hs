{- | The outer-host realization this binary is running on.

These tags describe the host so provider code can realize the universal
linux-cpu project substrate. They are provider-dispatch facts, not competing
project-visible execution contracts; projects do not declare a host matrix in
Python-owned config.

§ M gives pre-binary detection to the Python bootstrapper, which runs before
this binary exists and states what it found through the documented
invocation-context seam ('substrateEnvVar' and 'archEnvVar'). 'detect' reads
that statement. 'detectHere' is the fallback for a binary invoked directly,
with no bootstrapper in front of it — the one path on which this host is
classified a second time, taken only when nobody classified it once.

The classification core ('classify', 'parseDockerArch', 'parseStatedHost') is
pure; 'detectHere' wraps it with the platform reads and the NVIDIA probe.
-}
module HostBootstrap.Substrate (
    SubstrateName (..),
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
    parseSubstrateName,
    classify,
    detect,
    detectHere,
    substrateEnvVar,
    archEnvVar,
    parseStatedHost,
    nvidiaMarkerPaths,
    nvidiaDeviceMarker,
    hasNvidiaGpu,
    NvidiaProbePlan (..),
    nvidiaProbePlan,
    nvidiaProbeAnswer,
    nvidiaMarkerPathsFor,
)
where

import Data.Char (toLower)
import Data.List (isInfixOf)
import HostBootstrap.Effect.Run
    ( BoundedRun (..)
    , CapturedRun (capturedExit, capturedStdout)
    , RunBounds (..)
    , RunNamespace (..)
    , runBoundedGrouped
    )
import HostBootstrap.HostTool (HostTool (NvidiaSmi), absExePath, discover)
import System.Directory (doesPathExist, getCurrentDirectory)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, stderr)
import qualified System.Info as Info

-- | The supported outer-host realization tags.
data SubstrateName = AppleSilicon | LinuxCpu | LinuxGpu | WindowsCpu | WindowsGpu
    deriving (Eq, Show)

-- | Docker-style architecture.
data Arch = Amd64 | Arm64
    deriving (Eq, Show)

{- | A detected outer host paired with its Docker-style architecture. For
@apple-silicon@ the architecture is always 'Arm64'.
-}
data Substrate = Substrate
    { substrateName :: SubstrateName
    , substrateArch :: Arch
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

{- | The closed set of outer-host frames a behaviour is written once per
(@development_plan_standards.md § LL@).

Three, not five. The accelerator is a capability /of/ a frame rather than a
frame of its own: the package manager, the host provider, and the ownership
primitive are the same on @linux-cpu@ and @linux-gpu@, and re-spelling that
pair at every site that routes on the host is how a new substrate constructor
silently misses a case that reads as exhaustive. A behaviour that genuinely
differs by accelerator says so by /requiring/ one, not by naming two tags.
-}
data HostFrame
    = LinuxFrame
    | AppleFrame
    | WindowsFrame
    deriving (Eq, Ord, Show, Enum, Bounded)

-- | Every frame, for a total table.
allHostFrames :: [HostFrame]
allHostFrames = [minBound .. maxBound]

{- | The frame an outer host realizes.

This is the one place the five classification tags collapse to the three
frames, which is what makes 'isLinux', 'isWindows' and 'isAppleSilicon' one
derived fact rather than three independently maintained ones.
-}
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

{- | Whether this host carries an accelerator.

A total case rather than membership in a literal list: a substrate added to
the closed sum is a compile error here instead of a silent "no accelerator".
-}
hasGpu :: Substrate -> Bool
hasGpu s = case substrateName s of
    AppleSilicon -> False
    LinuxCpu -> False
    LinuxGpu -> True
    WindowsCpu -> False
    WindowsGpu -> True

-- | Read one rendered substrate tag back.
parseSubstrateName :: String -> Either String SubstrateName
parseSubstrateName raw = case raw of
    "apple-silicon" -> Right AppleSilicon
    "linux-cpu" -> Right LinuxCpu
    "linux-gpu" -> Right LinuxGpu
    "windows-cpu" -> Right WindowsCpu
    "windows-gpu" -> Right WindowsGpu
    other -> Left ("unsupported host substrate: " ++ other)

{- | Map a host machine string (e.g. from @uname -m@ / 'System.Info.arch') to a
Docker-style architecture. Pure.
-}
parseDockerArch :: String -> Either String Arch
parseDockerArch raw = case map toLower raw of
    "x86_64" -> Right Amd64
    "amd64" -> Right Amd64
    "aarch64" -> Right Arm64
    "arm64" -> Right Arm64
    other -> Left ("unsupported host architecture: " ++ other)

{- | The pure classification core: given the OS string ('System.Info.os'), the
raw machine architecture, and whether an NVIDIA GPU is present, return the
outer-host realization. Mirrors the branch structure of the Python @detect@.
-}
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

-- | The seam field naming the outer-host realization the bootstrapper detected.
substrateEnvVar :: String
substrateEnvVar = "HOSTBOOTSTRAP_HOST_SUBSTRATE"

-- | The seam field naming that host's architecture.
archEnvVar :: String
archEnvVar = "HOSTBOOTSTRAP_HOST_ARCH"

{- | Read the bootstrapper's statement of the host, when it made one.

Pure, over the two field values as they were found. 'Nothing' means no statement
was made and the caller classifies the host itself. A statement missing half of
itself is a refusal rather than a fallback: the sender claimed the seam, so
quietly re-deriving what it meant to say is how the two sides come to disagree.
-}
parseStatedHost :: Maybe String -> Maybe String -> Maybe (Either String Substrate)
parseStatedHost Nothing Nothing = Nothing
parseStatedHost statedName statedArch =
    Just $ do
        name <- required substrateEnvVar statedName >>= parseSubstrateName
        arch <- required archEnvVar statedArch >>= parseDockerArch
        case name of
            AppleSilicon -> classify "darwin" (renderArch arch) False
            _ -> pure (Substrate name arch)
  where
    required field = maybe (Left ("incomplete invocation context: " ++ field ++ " is unset")) Right

{- | The outer-host realization, as stated by the bootstrapper or classified here.

The stated answer wins, because § M gives the classification to the side that
runs first and one host classified twice agrees only until it does not.
-}
detect :: IO (Either String Substrate)
detect = do
    statedName <- lookupEnv substrateEnvVar
    statedArch <- lookupEnv archEnvVar
    case parseStatedHost statedName statedArch of
        Just stated -> pure stated
        Nothing -> detectHere

{- | Classify this host directly, for a binary invoked with no bootstrapper in
front of it. This is the fallback, not the ordinary path.
-}
detectHere :: IO (Either String Substrate)
detectHere = do
    hPutStrLn stderr "hostbootstrap: no bootstrapper host statement; classifying this host directly"
    gpu <- hasNvidiaGpu
    pure (classify Info.os Info.arch gpu)

-- | The kernel markers whose presence is an NVIDIA driver.
nvidiaMarkerPaths :: [FilePath]
nvidiaMarkerPaths = ["/proc/driver/nvidia/version", "/dev/nvidiactl"]

{- | The token an accelerator listing prints once per device.

Detection asks this question and so does every reconciler that gates on a GPU.
It is one string here rather than a literal at each of those sites, so
"@nvidia-smi@ reported a device" means the same thing in all of them.
-}
nvidiaDeviceMarker :: String
nvidiaDeviceMarker = "GPU"

-- | The next evidence read, decided without effects or a substitute executor.
data NvidiaProbePlan = NvidiaPresent | NvidiaAbsent | NvidiaListing
    deriving (Eq, Show)

-- | Kernel markers belong only to the Linux frame.
nvidiaMarkerPathsFor :: HostFrame -> [FilePath]
nvidiaMarkerPathsFor LinuxFrame = nvidiaMarkerPaths
nvidiaMarkerPathsFor AppleFrame = []
nvidiaMarkerPathsFor WindowsFrame = []

-- | macOS performs no probe; Windows never treats a Linux marker as evidence.
nvidiaProbePlan :: HostFrame -> Bool -> NvidiaProbePlan
nvidiaProbePlan LinuxFrame markerPresent = if markerPresent then NvidiaPresent else NvidiaListing
nvidiaProbePlan AppleFrame _ = NvidiaAbsent
nvidiaProbePlan WindowsFrame _ = NvidiaListing

-- | Only a successful bounded listing is device evidence. Missing tools,
-- timeouts, output limits and launch failures all answer "no GPU".
nvidiaProbeAnswer :: NvidiaProbePlan -> Maybe BoundedRun -> Bool
nvidiaProbeAnswer NvidiaPresent _ = True
nvidiaProbeAnswer NvidiaAbsent _ = False
nvidiaProbeAnswer NvidiaListing outcome = case outcome of
    Just (BoundedCompleted run) ->
        capturedExit run == ExitSuccess && nvidiaDeviceMarker `isInfixOf` capturedStdout run
    _ -> False

-- | Read this frame's markers, then a resolved, five-second bounded listing.
hasNvidiaGpu :: IO Bool
hasNvidiaGpu = case classify Info.os Info.arch False of
    Left _ -> pure False
    Right substrate -> do
        let frame = substrateFrame substrate
        markers <- mapM doesPathExist (nvidiaMarkerPathsFor frame)
        let plan = nvidiaProbePlan frame (or markers)
        case plan of
            NvidiaListing -> do
                executable <- discover NvidiaSmi
                case executable of
                    Nothing -> pure (nvidiaProbeAnswer plan Nothing)
                    Just smi -> do
                        directory <- getCurrentDirectory
                        environment <- getEnvironment
                        outcome <-
                            runBoundedGrouped
                                RunBounds
                                    { boundWallMicros = 5000000
                                    , boundOutputBytes = 65536
                                    , boundTerminationGraceMicros = 500000
                                    }
                                (RunNamespace directory environment)
                                (absExePath smi)
                                ["-L"]
                        pure (nvidiaProbeAnswer plan (Just outcome))
            _ -> pure (nvidiaProbeAnswer plan Nothing)
