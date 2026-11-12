{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The closed enumeration of external tools and their absolute-path
resolution.

Host-tool resolution doctrine (see @development_plan_standards.md § K@): every
external tool is a constructor of the closed 'HostTool' type, and every
invocation reads an absolute path. The 'AbsExe' newtype makes a bare command
name unrepresentable as a resolved tool — the smart constructor 'mkAbsExe'
rejects relative paths. Bare command names are used only for discovery
('toolCommandName' / 'discover'), never for invocation.
-}
module HostBootstrap.HostTool (
    HostTool (..),
    allHostTools,
    toolCommandName,
    AbsExe,
    absExePath,
    mkAbsExe,
    hostToolProcessArguments,
    discover,
    ghcupBinCandidates,
    cudaCandidatePaths,
    newestToolkitVersions,
)
where

import Control.Exception (IOException, catch)
import Data.List (isPrefixOf, sortBy, stripPrefix)
import Data.Maybe (mapMaybe)
import Data.Ord (comparing)
import System.Directory (doesDirectoryExist, doesFileExist, findExecutable, listDirectory)
import System.FilePath (isAbsolute, takeFileName)
import qualified System.FilePath.Posix as Posix
import Text.Read (readMaybe)
#ifdef mingw32_HOST_OS
import HostBootstrap.Effect.Run (CapturedRun (capturedExit, capturedStdout), runCaptured)
import System.Exit (ExitCode (ExitSuccess))
import System.Environment (lookupEnv)
-- Every native-separator join below is a Windows fallback path, so importing
-- '(</>)' unconditionally is an unused import on every other host and fails the
-- gate's own @-Werror@ on a tree that compiles this module from scratch.
import System.FilePath ((</>))
#else
import System.Environment (getEnvironment)
#endif

-- | The closed set of external tools @hostbootstrap-core@ resolves.
data HostTool
    = Docker
    | Colima
    | Lima
    | Brew
    | Ghc
    | Ghcup
    | Kubectl
    | Helm
    | Kind
    | Nvkind
    | Mc
    | NvidiaSmi
    | Nvcc
    | Swiftc
    | Xcrun
    | SystemProfiler
    | Clang
    | Clangxx
    | MsvcCl
    | Vswhere
    | PowerShell
    | Bcdedit
    | Sysctl
    | Winget
    | Wsl
    | Sudo
    | XcodeSelect
    | Incus
    | Df
    | Kill
    | Ps
    | Tar
    | Curl
    | Virtiofsd
    deriving (Eq, Ord, Show, Enum, Bounded)

-- | Every host tool, for building a fully-resolved 'HostBootstrap.HostConfig'.
allHostTools :: [HostTool]
allHostTools = [minBound .. maxBound]

{- | The bare command name. Used only to discover the absolute path; never used
as a @$PATH@-resolved invocation target.
-}
toolCommandName :: HostTool -> String
toolCommandName Docker = "docker"
toolCommandName Colima = "colima"
toolCommandName Lima = "limactl"
toolCommandName Brew = "brew"
toolCommandName Ghc = "ghc"
toolCommandName Ghcup = "ghcup"
toolCommandName Kubectl = "kubectl"
toolCommandName Helm = "helm"
toolCommandName Kind = "kind"
toolCommandName Nvkind = "nvkind"
toolCommandName Mc = "mc"
toolCommandName NvidiaSmi = "nvidia-smi"
toolCommandName Nvcc = "nvcc"
toolCommandName Swiftc = "swiftc"
toolCommandName Xcrun = "xcrun"
toolCommandName SystemProfiler = "system_profiler"
toolCommandName Clang = "clang"
toolCommandName Clangxx = "clang++"
toolCommandName MsvcCl = "cl.exe"
toolCommandName Vswhere = "vswhere.exe"
toolCommandName PowerShell = "powershell.exe"
toolCommandName Bcdedit = "bcdedit"
toolCommandName Sysctl = "sysctl"
toolCommandName Winget = "winget"
toolCommandName Wsl = "wsl"
toolCommandName Sudo = "sudo"
toolCommandName XcodeSelect = "xcode-select"
toolCommandName Incus = "incus"
toolCommandName Df = "df"
toolCommandName Kill = "kill"
toolCommandName Ps = "ps"
toolCommandName Tar = "tar"
toolCommandName Curl = "curl"
toolCommandName Virtiofsd = "virtiofsd"

{- | An absolute path to a resolved executable. The constructor is not exported;
'mkAbsExe' is the only way to build one, so a value of this type is always an
absolute path.
-}
newtype AbsExe = AbsExe FilePath
    deriving (Eq, Ord, Show)

-- | The absolute path admitted by 'mkAbsExe'. This accessor permits no update.
absExePath :: AbsExe -> FilePath
absExePath (AbsExe path) = path

{- | Build an 'AbsExe', rejecting anything that is not an absolute path (in
particular a bare command name).
-}
mkAbsExe :: FilePath -> Either String AbsExe
mkAbsExe fp
    | isAbsolute fp = Right (AbsExe fp)
    | otherwise = Left ("not an absolute path: " ++ fp)

{- | Adapt a resolved tool's option vector to its native process parser.

Windows supplies the application path to @CreateProcess@ separately from the
serialized command line. Most programs reconstruct their program-name token,
but @wsl.exe@ consumes the first serialized token as @argv[0]@. Prefixing its
basename keeps its first real option (normally @-d@) in the option position.
-}
hostToolProcessArguments :: HostTool -> AbsExe -> [String] -> [String]
hostToolProcessArguments Wsl executable arguments = takeFileName (absExePath executable) : arguments
hostToolProcessArguments _tool _executable arguments = arguments

{- | Discover a tool's absolute path. 'System.Directory.findExecutable' returns
an absolute path when the command is found on the search path; the result is
re-validated through 'mkAbsExe' so a non-absolute hit is rejected.
POSIX GHC tools also search 'ghcupBinCandidates' when absent from that path.
-}
discover :: HostTool -> IO (Maybe AbsExe)
#ifdef mingw32_HOST_OS
discover Wsl = discoverWindowsSystemTool Wsl "wsl.exe"
discover Bcdedit = discoverWindowsSystemTool Bcdedit "bcdedit.exe"
#else
discover Wsl = pure Nothing

discover Bcdedit = pure Nothing
#endif
discover tool = do
    found <- findHostExecutable (toolCommandName tool)
    case found of
        Just fp -> pure (either (const Nothing) Just (mkAbsExe fp))
        Nothing -> discoverFallback tool

{- | The POSIX ghcup binary directory: a configured install-base prefix wins,
otherwise the home directory supplies the root. The paths describe a POSIX
frame even when this pure helper is evaluated on a different host.
-}
ghcupBinCandidates :: [(String, String)] -> [FilePath]
ghcupBinCandidates environment =
    [ root Posix.</> ".ghcup" Posix.</> "bin"
    | Just root <- [installBase]
    ]
  where
    installBase = case lookup "GHCUP_INSTALL_BASE_PREFIX" environment of
        Just root -> Just root
        Nothing -> lookup "HOME" environment

#ifdef mingw32_HOST_OS
discoverWindowsSystemTool :: HostTool -> FilePath -> IO (Maybe AbsExe)
discoverWindowsSystemTool tool name = do
  root <- lookupEnv "SystemRoot"
  preferred <- firstExisting [directory </> "System32" </> name | Just directory <- [root]]
  case preferred of
    Just executable -> pure (Just executable)
    Nothing -> do
      found <- findHostExecutable (toolCommandName tool)
      pure (found >>= either (const Nothing) Just . mkAbsExe)

windowsProgramRoots :: IO [FilePath]
windowsProgramRoots = mapMaybe id <$> traverse lookupEnv ["ProgramFiles", "ProgramFiles(x86)"]
#endif

findHostExecutable :: String -> IO (Maybe FilePath)
#ifdef mingw32_HOST_OS
findHostExecutable name = firstFound [name, name <> ".exe", name <> ".com", name <> ".bat", name <> ".cmd"]
  where
    firstFound [] = pure Nothing
    firstFound (candidate : remaining) = do
      found <- findExecutable candidate
      maybe (firstFound remaining) (pure . Just) found
#else
findHostExecutable = findExecutable
#endif

discoverFallback :: HostTool -> IO (Maybe AbsExe)
#ifdef mingw32_HOST_OS
discoverFallback Nvcc = discoverWindowsNvcc
discoverFallback Clang = windowsLlvmTool "clang.exe"

discoverFallback Clangxx = windowsLlvmTool "clang++.exe"
discoverFallback MsvcCl = discoverWindowsMsvcCl
discoverFallback Vswhere = do
  roots <- reverse <$> windowsProgramRoots
  firstExisting [root </> "Microsoft Visual Studio" </> "Installer" </> "vswhere.exe" | root <- roots]
discoverFallback _ = pure Nothing

windowsLlvmTool :: FilePath -> IO (Maybe AbsExe)
windowsLlvmTool name = do
  roots <- windowsProgramRoots
  firstExisting [root </> "LLVM" </> "bin" </> name | root <- roots]

discoverWindowsNvcc :: IO (Maybe AbsExe)
discoverWindowsNvcc = do
  roots <- windowsProgramRoots
  firstWindowsVersionedTool
    [root </> "NVIDIA GPU Computing Toolkit" </> "CUDA" | root <- roots]
    ("bin" </> "nvcc.exe")

discoverWindowsMsvcCl :: IO (Maybe AbsExe)
discoverWindowsMsvcCl = do
  found <- discoverWindowsMsvcClViaVswhere
  case found of
    Just exe -> pure (Just exe)
    Nothing -> discoverWindowsMsvcClFromKnownRoots

discoverWindowsMsvcClViaVswhere :: IO (Maybe AbsExe)
discoverWindowsMsvcClViaVswhere =
  ( do
      mVswhere <- discover Vswhere
      case mVswhere of
        Nothing -> pure Nothing
        Just vswhere -> do
          -- Discovery runs before any tool is resolved, so it names no described
          -- effect (§ KK): a described effect's target /is/ a resolved tool, and
          -- this probe is what produces one. It still spawns through the one
          -- runner, so the descriptor and exception disposition is the same.
          outcome <-
            runCaptured
              (absExePath vswhere)
              [ "-latest",
                "-products",
                "*",
                "-requires",
                "Microsoft.VisualStudio.Workload.VCTools",
                "-find",
                "VC\\Tools\\MSVC\\**\\bin\\Hostx64\\x64\\cl.exe"
              ]
              ""
          case outcome of
            Right run
              | capturedExit run == ExitSuccess ->
                  firstExisting (filter (not . null) (lines (capturedStdout run)))
            _ -> pure Nothing
  )
    `catch` \(_ :: IOException) -> pure Nothing

discoverWindowsMsvcClFromKnownRoots :: IO (Maybe AbsExe)
discoverWindowsMsvcClFromKnownRoots = do
  folders <- windowsProgramRoots
  let roots =
        [ folder </> "Microsoft Visual Studio" </> "2022" </> edition </> "VC" </> "Tools" </> "MSVC"
        | folder <- reverse folders
        , edition <- ["BuildTools", "Community", "Professional", "Enterprise"]
        ]
  firstWindowsVersionedTool roots ("bin" </> "Hostx64" </> "x64" </> "cl.exe")
#else
discoverFallback Ghc = discoverPosixGhcupTool Ghc

discoverFallback Ghcup = discoverPosixGhcupTool Ghcup

discoverFallback Nvcc = discoverPosixCudaTool "nvcc"
discoverFallback _ = pure Nothing

discoverPosixGhcupTool :: HostTool -> IO (Maybe AbsExe)
discoverPosixGhcupTool tool = do
  environment <- getEnvironment
  firstExisting [directory Posix.</> toolCommandName tool | directory <- ghcupBinCandidates environment]

{- | The CUDA toolkit's canonical POSIX location. A distribution or container
image installs @nvcc@ under @/usr/local/cuda@ (a symlink to the versioned root)
without necessarily putting that @bin@ directory on @PATH@ — the published CUDA
base image is exactly such an image. Discovering it here is the POSIX peer of
'discoverWindowsNvcc' and keeps § K's promise that a present toolchain resolves
to an absolute path instead of being reported absent.
-}
discoverPosixCudaTool :: String -> IO (Maybe AbsExe)
discoverPosixCudaTool name = do
  exists <- doesDirectoryExist cudaPrefix
  entries <- if exists then safeListDirectory cudaPrefix else pure []
  firstExisting (cudaCandidatePaths name entries)
#endif

safeListDirectory :: FilePath -> IO [FilePath]
safeListDirectory path = listDirectory path `catch` \(_ :: IOException) -> pure []

cudaPrefix :: FilePath
cudaPrefix = "/usr/local"

{- | Where a POSIX CUDA tool may live, in the order it should be preferred: the
stable unversioned @\/usr\/local\/cuda@ symlink first, then any versioned
sibling newest-first. Pure so the ordering is unit-tested rather than inferred
from whichever toolkit a particular host happens to carry.
-}
cudaCandidatePaths :: String -> [FilePath] -> [FilePath]
cudaCandidatePaths name entries =
    [ root Posix.</> "bin" Posix.</> name
    | root <-
        (cudaPrefix Posix.</> "cuda")
            : [ cudaPrefix Posix.</> entry
              | entry <- newestToolkitVersions entries
              , "cuda-" `isPrefixOf` entry
              ]
    ]

-- | Numeric toolkit versions, newest first; non-version directory names are ignored.
newestToolkitVersions :: [FilePath] -> [FilePath]
newestToolkitVersions = map snd . sortBy (flip (comparing fst)) . mapMaybe numbered
  where
    numbered :: FilePath -> Maybe ([Integer], FilePath)
    numbered name = do
        let version = case stripPrefix "cuda-" name of
                Just suffix -> suffix
                Nothing -> maybe name id (stripPrefix "v" name)
        components <- traverse readMaybe (splitDots version)
        pure (components, name)

    splitDots value = case break (== '.') value of
        (component, '.' : rest) -> component : splitDots rest
        (component, []) -> [component]
        _ -> []

#ifdef mingw32_HOST_OS
firstWindowsVersionedTool :: [FilePath] -> FilePath -> IO (Maybe AbsExe)
firstWindowsVersionedTool [] _ = pure Nothing
firstWindowsVersionedTool (root : roots) suffix = do
  exists <- doesDirectoryExist root
  if not exists
    then firstWindowsVersionedTool roots suffix
    else do
      versions <- safeListDirectory root
      found <- firstExisting [root </> version </> suffix | version <- newestToolkitVersions versions]
      case found of
        Just exe -> pure (Just exe)
        Nothing -> firstWindowsVersionedTool roots suffix

#endif

firstExisting :: [FilePath] -> IO (Maybe AbsExe)
firstExisting [] = pure Nothing
firstExisting (path : paths) = do
    exists <- doesFileExist path
    if exists
        then pure (either (const Nothing) Just (mkAbsExe path))
        else firstExisting paths
