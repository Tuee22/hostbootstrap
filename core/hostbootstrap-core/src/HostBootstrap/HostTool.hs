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
    discover,
    cudaCandidatePaths,
)
where

import Control.Exception (IOException, catch)
import System.Directory (doesDirectoryExist, doesFileExist, findExecutable, listDirectory)
import Data.List (isPrefixOf, sort)
import System.FilePath (isAbsolute, (</>))
#ifdef mingw32_HOST_OS
import System.Exit (ExitCode (ExitSuccess))
import System.Process (readProcessWithExitCode)
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

{- | An absolute path to a resolved executable. The constructor is not exported;
'mkAbsExe' is the only way to build one, so a value of this type is always an
absolute path.
-}
newtype AbsExe = AbsExe {absExePath :: FilePath}
    deriving (Eq, Ord, Show)

{- | Build an 'AbsExe', rejecting anything that is not an absolute path (in
particular a bare command name).
-}
mkAbsExe :: FilePath -> Either String AbsExe
mkAbsExe fp
    | isAbsolute fp = Right (AbsExe fp)
    | otherwise = Left ("not an absolute path: " ++ fp)

{- | Discover a tool's absolute path. 'System.Directory.findExecutable' returns
an absolute path when the command is found on the search path; the result is
re-validated through 'mkAbsExe' so a non-absolute hit is rejected.
-}
discover :: HostTool -> IO (Maybe AbsExe)
#ifdef mingw32_HOST_OS
discover Wsl = firstExisting ["C:\\Windows\\System32\\wsl.exe"]
discover Bcdedit = firstExisting ["C:\\Windows\\System32\\bcdedit.exe"]
#endif
discover tool = do
    found <- findExecutable (toolCommandName tool)
    case found of
        Just fp -> pure (either (const Nothing) Just (mkAbsExe fp))
        Nothing -> discoverFallback tool

discoverFallback :: HostTool -> IO (Maybe AbsExe)
#ifdef mingw32_HOST_OS
discoverFallback Nvcc = discoverWindowsNvcc
discoverFallback Clang = firstExisting ["C:\\Program Files\\LLVM\\bin\\clang.exe"]
discoverFallback MsvcCl = discoverWindowsMsvcCl
discoverFallback Vswhere = firstExisting ["C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe"]
discoverFallback _ = pure Nothing

discoverWindowsNvcc :: IO (Maybe AbsExe)
discoverWindowsNvcc = do
  let root = "C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA"
  exists <- doesDirectoryExist root
  if not exists
    then pure Nothing
    else do
      versions <- safeListDirectory root
      firstExisting [root </> version </> "bin" </> "nvcc.exe" | version <- reverse versions]

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
          (exitCode, out, _) <-
            readProcessWithExitCode
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
          case exitCode of
            ExitSuccess -> firstExisting (filter (not . null) (lines out))
            _ -> pure Nothing
  )
    `catch` \(_ :: IOException) -> pure Nothing

discoverWindowsMsvcClFromKnownRoots :: IO (Maybe AbsExe)
discoverWindowsMsvcClFromKnownRoots = do
  let roots =
        [ "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\MSVC",
          "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\Community\\VC\\Tools\\MSVC",
          "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\Professional\\VC\\Tools\\MSVC",
          "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\Enterprise\\VC\\Tools\\MSVC",
          "C:\\Program Files\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\MSVC",
          "C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Tools\\MSVC",
          "C:\\Program Files\\Microsoft Visual Studio\\2022\\Professional\\VC\\Tools\\MSVC",
          "C:\\Program Files\\Microsoft Visual Studio\\2022\\Enterprise\\VC\\Tools\\MSVC"
        ]
  firstWindowsVersionedTool roots ("bin" </> "Hostx64" </> "x64" </> "cl.exe")
#else
discoverFallback Nvcc = discoverPosixCudaTool "nvcc"
discoverFallback _ = pure Nothing

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
  [ root </> "bin" </> name
  | root <-
      (cudaPrefix </> "cuda")
        : [ cudaPrefix </> entry
          | entry <- reverse (sort entries)
          , "cuda-" `isPrefixOf` entry
          ]
  ]

#ifdef mingw32_HOST_OS
firstWindowsVersionedTool :: [FilePath] -> FilePath -> IO (Maybe AbsExe)
firstWindowsVersionedTool [] _ = pure Nothing
firstWindowsVersionedTool (root : roots) suffix = do
  exists <- doesDirectoryExist root
  if not exists
    then firstWindowsVersionedTool roots suffix
    else do
      versions <- safeListDirectory root
      found <- firstExisting [root </> version </> suffix | version <- reverse versions]
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
