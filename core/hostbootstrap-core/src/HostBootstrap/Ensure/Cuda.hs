{-# LANGUAGE OverloadedStrings #-}

{- | The @ensure cuda@ reconciler: the NVIDIA driver and container runtime on
@linux-gpu@.

Install-and-verify (see @development_plan_standards.md § L@): the kernel
driver (@nvidia-smi@) is a precondition — a kernel driver is not auto-installed
here — but the NVIDIA container toolkit and its Docker runtime registration are
installed and verified. A verified no-op only when the exact @nvkind@
volume-mount injection path can see a GPU. Missing repository tools are installed
before an owned scratch stage fetches and validates the repository inputs. The
real 'installSteps' runtime tail follows that stage and verifies the same smoke.
-}
module HostBootstrap.Ensure.Cuda (
    reconciler,
    installSteps,
    repositoryToolSteps,
    repositoryFetchSteps,
    repositoryPublishSteps,
    signedByListText,
    setupRepositoryWith,
    nvkindRuntimeProbeArgs,
)
where

import Control.Exception (displayException)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import HostBootstrap.Ensure (
    FramePlan (InstallHere),
    InstallStep (..),
    Reconciler (..),
    frameTable,
    installAndVerify,
    linuxGpuRow,
    reconcilerInstallSteps,
    reportedGpu,
    runTool,
    toolPresent,
 )
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.HostTool (HostTool (Curl, Docker, NvidiaSmi, Sudo), toolCommandName)
import HostBootstrap.Substrate (Substrate)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>))
import System.IO.Error (tryIOError)
import System.IO.Temp (withSystemTempDirectory)

reconciler :: Reconciler
reconciler =
    Reconciler
        { reconcilerName = "cuda"
        , reconcilerSummary = "Ensure the NVIDIA driver and Docker runtime (linux-gpu)"
        , -- One row, and the only one in the package that requires an
          -- accelerator of the frame it runs in rather than naming a tag.
          reconcilerFrames = frameTable [linuxGpuRow (InstallHere linuxGpuSteps)]
        , reconcile = reconcileCuda
        }

reconcileCuda :: HostConfig -> IO ()
reconcileCuda cfg = do
    if not (toolPresent cfg NvidiaSmi)
        then die "ensure cuda: nvidia-smi not found; install the NVIDIA driver, then re-run."
        else do
            driver <- runTool cfg NvidiaSmi ["-L"]
            if not (reportedGpu driver)
                then die "ensure cuda: nvidia-smi did not report a GPU; repair the NVIDIA driver, then re-run."
                else do
                    ready <- satisfied cfg
                    if ready
                        then putStrLn "ensure cuda: present (no-op)"
                        else case installSteps (hcSubstrate cfg) of
                            Left err -> die ("ensure cuda: " ++ err)
                            Right _ -> do
                                installAndVerify "cuda repository tools" repositoryToolsPresent (const (Right repositoryToolSteps)) cfg
                                refreshed <- buildHostConfig (hcSubstrate cfg)
                                repository <- setupRepositoryWith (runTool refreshed)
                                case repository of
                                    Left err -> die ("ensure cuda: " ++ err)
                                    Right () -> installAndVerify "cuda" satisfied installSteps refreshed

repositoryToolsPresent :: HostConfig -> IO Bool
repositoryToolsPresent cfg
    | not (toolPresent cfg Curl) = pure False
    | otherwise = do
        result <- runTool cfg Sudo ["gpg", "--version"]
        pure $ case result of
            Right (ExitSuccess, _, _) -> True
            _ -> False

{- | CUDA is satisfied when the host driver reports a GPU and the exact
@nvkind@ volume-mount injection smoke can see it from Docker. The latter proves
the NVIDIA runtime is the default and
@accept-nvidia-visible-devices-as-volume-mounts@ is effective; merely listing
an @nvidia@ runtime is not sufficient for GPU-enabled kind nodes.
-}
satisfied :: HostConfig -> IO Bool
satisfied cfg = do
    smi <- runTool cfg NvidiaSmi ["-L"]
    case smi of
        result | reportedGpu result -> do
            smoke <- runTool cfg Docker nvkindRuntimeProbeArgs
            pure (reportedGpu smoke)
        _ -> pure False

-- | NVIDIA's documented @nvkind@ toolkit smoke.
nvkindRuntimeProbeArgs :: [String]
nvkindRuntimeProbeArgs =
    [ "run"
    , "--rm"
    , "-v"
    , "/dev/null:/var/run/nvidia-container-devices/all"
    , "ubuntu:20.04"
    , "nvidia-smi"
    , "-L"
    ]

{- | The substrate-branched runtime tail, consumed after repository setup:
refresh apt, install the NVIDIA container toolkit, register it as Docker's
default with CDI, enable the volume-mount injection @nvkind@ consumes, and
restart the daemon. Repository-tool installation and scratch preparation are
separate runtime stages.
-}
installSteps :: Substrate -> Either String [InstallStep]
installSteps = reconcilerInstallSteps reconciler

linuxGpuSteps :: [InstallStep]
linuxGpuSteps =
    [ InstallStep Sudo ["apt-get", "update"]
    , InstallStep Sudo ["apt-get", "install", "-y", "nvidia-container-toolkit"]
    , InstallStep Sudo ["nvidia-ctk", "runtime", "configure", "--runtime=docker", "--set-as-default", "--cdi.enabled"]
    , InstallStep Sudo ["nvidia-ctk", "config", "--set", "accept-nvidia-visible-devices-as-volume-mounts=true", "--in-place"]
    , InstallStep Sudo ["systemctl", "restart", "docker"]
    ]

-- | Real bootstrap commands, skipped when Curl and @gpg --version@ are ready.
repositoryToolSteps :: [InstallStep]
repositoryToolSteps =
    [ InstallStep Sudo ["apt-get", "update"]
    , InstallStep Sudo ["apt-get", "install", "-y", "--no-install-recommends", "curl", "gnupg2"]
    ]

-- | Downloads into the owned scratch directory, before either destination write.
repositoryFetchSteps :: FilePath -> [InstallStep]
repositoryFetchSteps scratch =
    [ InstallStep Curl ["-fsSL", "-o", scratch </> "nvidia-container-toolkit.key", "https://nvidia.github.io/libnvidia-container/gpgkey"]
    , InstallStep Curl ["-fsSL", "-o", scratch </> "nvidia-container-toolkit.list", "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"]
    ]

-- | Publication commands, consumed only after both downloads are validated.
repositoryPublishSteps :: FilePath -> [InstallStep]
repositoryPublishSteps scratch =
    [ InstallStep Sudo ["gpg", "--dearmor", "--yes", "-o", "/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg", scratch </> "nvidia-container-toolkit.key"]
    , InstallStep Sudo ["install", "-m", "0644", scratch </> "nvidia-container-toolkit.signed.list", "/etc/apt/sources.list.d/nvidia-container-toolkit.list"]
    ]

{- | Add the fixed keyring to every supported active NVIDIA binary-repository
line. Other active syntax refuses rather than leaving any unsigned row.
Comments, blank lines, literal @$(ARCH)@, and the final newline are preserved.
-}
signedByListText :: Text -> Either String Text
signedByListText body = do
    rows <- mapM rewrite (T.splitOn "\n" body)
    if any fst rows
        then Right (T.intercalate "\n" (map snd rows))
        else Left "NVIDIA repository list has no supported deb https:// entry"
  where
    rewrite line
        | T.null (T.strip line) || "#" `T.isPrefixOf` content = Right (False, line)
        | Just rest <- T.stripPrefix "deb " content
        , [url, "/"] <- T.words rest
        , "https://nvidia.github.io/libnvidia-container/" `T.isPrefixOf` url =
            Right (True, indentation <> "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] " <> rest)
        | otherwise = Left "NVIDIA repository list has an unsupported active line"
      where
        content = T.stripStart line
        indentation = T.take (T.length line - T.length content) line

{- | Fetch and validate strict bytes in an owned scratch directory, then publish
the keyring and rewritten list. Ordinary IO failures refuse and cleanup runs on
every exit; asynchronous exceptions propagate. Fetch/content refusal precedes
both privileged destination commands. Once publication starts it is not an
atomic two-file transaction and a later failure does not roll back earlier work.
-}
setupRepositoryWith ::
    (HostTool -> [String] -> IO (Either String (ExitCode, String, String))) ->
    IO (Either String ())
setupRepositoryWith run = do
    result <- tryIOError $ withSystemTempDirectory "hostbootstrap-cuda-repository" $ \scratch -> do
        fetched <- runRepositorySteps run (repositoryFetchSteps scratch)
        case fetched of
            Left err -> pure (Left err)
            Right () -> do
                key <- BS.readFile (scratch </> "nvidia-container-toolkit.key")
                list <- BS.readFile (scratch </> "nvidia-container-toolkit.list")
                if BS.null key
                    then pure (Left "NVIDIA repository key is empty")
                    else if BS.null list
                        then pure (Left "NVIDIA repository list is empty")
                        else case TE.decodeUtf8' list of
                            Left _ -> pure (Left "NVIDIA repository list is not UTF-8")
                            Right text -> case signedByListText text of
                                Left err -> pure (Left err)
                                Right signed -> do
                                    BS.writeFile (scratch </> "nvidia-container-toolkit.signed.list") (TE.encodeUtf8 signed)
                                    runRepositorySteps run (repositoryPublishSteps scratch)
    pure (either (Left . ("NVIDIA repository IO failure: " ++) . displayException) id result)

runRepositorySteps ::
    (HostTool -> [String] -> IO (Either String (ExitCode, String, String))) ->
    [InstallStep] ->
    IO (Either String ())
runRepositorySteps _ [] = pure (Right ())
runRepositorySteps run (InstallStep tool argv : rest) = do
    result <- run tool argv
    case result of
        Left err -> pure (Left err)
        Right (ExitFailure code, _, err) ->
            pure (Left ("NVIDIA repository command failed (exit " ++ show code ++ "): " ++ unwords (toolCommandName tool : argv) ++ " " ++ err))
        Right (ExitSuccess, _, _) -> runRepositorySteps run rest
