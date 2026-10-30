{-# LANGUAGE CPP #-}

{- | The @ensure docker@ reconciler: a reachable Docker daemon on every substrate.

Install-and-verify (see @development_plan_standards.md § L@): on Linux,
refresh apt, install Docker and buildx, enable the daemon, grant the invoking
non-root user membership in @docker@, and check its recorded groups against the
socket's owning group and group-write bit. Apply a user ACL when needed so the
current process can use Docker before a relogin. On Apple silicon Docker is
provided by the prepared per-project Colima provider wall, so this
config-free planner refuses rather than attempting a host-package install.
The pure
'installSteps' planner and target-user selector are unit-tested.
-}
module HostBootstrap.Ensure.Docker (reconciler, installSteps, verifyDockerGroupWith) where

import Control.Exception (displayException)
import Control.Monad (when)
import HostBootstrap.Ensure (
    FramePlan (InstallHere, ProvidedElsewhere),
    InstallStep (..),
    Reconciler (..),
    appleRow,
    frameTable,
    grantSocketAccess,
    installAndVerify,
    linuxRow,
    reconcilerInstallSteps,
    runTool,
    windowsRow,
    withInvokingGroupMember,
 )
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Docker, Sudo))
import HostBootstrap.Substrate (Substrate, isLinux)
import System.Exit (ExitCode (..), die)
import System.IO.Error (tryIOError)
#ifndef mingw32_HOST_OS
import System.Posix.Files (fileGroup, fileMode, getFileStatus, groupWriteMode, intersectFileModes)
import System.Posix.User (getGroupEntryForID, groupName)
#endif

reconciler :: Reconciler
reconciler =
    Reconciler
        { reconcilerName = "docker"
        , reconcilerSummary = "Ensure the Docker daemon is installed and reachable"
        , -- Three rows, because a reachable daemon is required on every frame but
          -- installed on only one. Apple and Windows are probe-only rather than
          -- absent: an already-reachable daemon there is a verified no-op, and only
          -- an absent one is refused, naming the frame that owns it.
          reconcilerFrames =
            frameTable
                [ linuxRow
                    ( InstallHere
                        [ InstallStep Sudo ["apt-get", "update"]
                        , InstallStep Sudo ["apt-get", "install", "-y", "docker.io", "docker-buildx", "acl"]
                        , InstallStep Sudo ["systemctl", "enable", "--now", "docker"]
                        ]
                    )
                , appleRow
                    ( ProvidedElsewhere
                        "on Apple silicon Docker is provided by the prepared per-project Colima provider wall"
                    )
                , windowsRow
                    ( ProvidedElsewhere
                        "docker is reconciled by the Windows WSL2 host-provider path, not `ensure docker`"
                    )
                ]
        , reconcile = reconcileDocker
        }

reconcileDocker :: HostConfig -> IO ()
reconcileDocker cfg = do
    installAndVerify "docker" daemonReachable installSteps cfg
    when (isLinux (hcSubstrate cfg)) (ensureDockerGroup cfg)

dockerInfo :: HostConfig -> IO Bool
dockerInfo cfg = do
    result <- runTool cfg Docker ["info"]
    pure $ case result of
        Right (ExitSuccess, _, _) -> True
        _ -> False

{- | Docker is satisfied when the daemon is reachable. On Linux the immediate
Haskell process cannot observe group membership added during this run, so the
install probe accepts @sudo docker info@ for daemon reachability; the
follow-up group check observes the future login's group-based socket
permissions without executing that login or proving daemon connectivity.
-}
daemonReachable :: HostConfig -> IO Bool
daemonReachable cfg
    | isLinux (hcSubstrate cfg) = do
        buildx <- dockerBuildxPresent cfg
        direct <- dockerInfo cfg
        if direct
            then pure buildx
            else (buildx &&) <$> sudoDockerInfo cfg
    | otherwise = (&&) <$> dockerInfo cfg <*> dockerBuildxPresent cfg

dockerBuildxPresent :: HostConfig -> IO Bool
dockerBuildxPresent cfg = do
    result <- runTool cfg Docker ["buildx", "version"]
    pure $ case result of
        Right (ExitSuccess, _, _) -> True
        _ -> False

sudoDockerInfo :: HostConfig -> IO Bool
sudoDockerInfo cfg = do
    result <- runTool cfg Sudo ["docker", "info"]
    pure $ case result of
        Right (ExitSuccess, _, _) -> True
        _ -> False

installSteps :: Substrate -> Either String [InstallStep]
installSteps = reconcilerInstallSteps reconciler

ensureDockerGroup :: HostConfig -> IO ()
ensureDockerGroup cfg =
    withInvokingGroupMember cfg dockerLabel "docker" (verifyDockerGroup cfg)

-- | The reconciler's name in every message it prints or dies with.
dockerLabel :: String
dockerLabel = "ensure docker"

-- | The daemon socket an invocation needs open before its group login exists.
dockerSocketPath :: FilePath
dockerSocketPath = "/var/run/docker.sock"

{- | Check the selected user's recorded groups against the live socket's owning
group and write bit before the current-session Docker probe and ACL work.
This describes group-based access; it does not execute a future login.
-}
verifyDockerGroup :: HostConfig -> (String -> [String] -> IO ()) -> String -> IO ()
verifyDockerGroup cfg checkedStep user = do
    verified <- verifyDockerGroupWith (runTool cfg Sudo) readDockerSocketGroup user
    case verified of
        Left err -> die (dockerLabel ++ ": " ++ err)
        Right () -> ensureCurrentSessionSocketAccess cfg checkedStep user

{- | Observe groups with the result-producing privileged runner, then inspect
the socket's actual owning group and group-write bit. Command failure skips the
socket observation. Refusal precedes the caller's current-session access work.
Ordinary IO failures refuse; asynchronous exceptions propagate.
-}
verifyDockerGroupWith ::
    ([String] -> IO (Either String (ExitCode, String, String))) ->
    IO (Either String (String, Bool)) ->
    String ->
    IO (Either String ())
verifyDockerGroupWith runSudo observeSocket user = do
    result <- tryIOError $ do
        groups <- runSudo ["id", "-nG", user]
        case groups of
            Left err -> pure (Left ("could not read groups for " ++ user ++ ": " ++ err))
            Right (ExitFailure code, _, err) ->
                pure (Left ("could not read groups for " ++ user ++ " (exit " ++ show code ++ ") " ++ err))
            Right (ExitSuccess, out, _) -> do
                socket <- observeSocket
                pure $ do
                    (owningGroup, writable) <- socket
                    if owningGroup `notElem` words out
                        then Left (user ++ " is not a member of Docker socket group " ++ owningGroup)
                        else if not writable
                            then Left ("Docker socket is not writable by owning group " ++ owningGroup)
                            else Right ()
    pure (either (Left . ("could not verify Docker group access: " ++) . displayException) id result)

readDockerSocketGroup :: IO (Either String (String, Bool))
#ifdef mingw32_HOST_OS
readDockerSocketGroup =
    pure (Left "Docker socket group inspection is unavailable on native Windows")
#else
readDockerSocketGroup = do
    observed <- tryIOError $ do
        status <- getFileStatus dockerSocketPath
        owner <- getGroupEntryForID (fileGroup status)
        pure (groupName owner, intersectFileModes (fileMode status) groupWriteMode /= 0)
    pure (either (Left . ("could not inspect Docker socket permissions: " ++) . displayException) Right observed)
#endif

ensureCurrentSessionSocketAccess :: HostConfig -> (String -> [String] -> IO ()) -> String -> IO ()
ensureCurrentSessionSocketAccess cfg checkedStep user = do
    direct <- dockerInfo cfg
    if direct
        then reportDockerAccessVerified
        else do
            ensureAclTool checkedStep
            grantSocketAccess checkedStep dockerSocketPath user
            reportDockerAccessVerified

ensureAclTool :: (String -> [String] -> IO ()) -> IO ()
ensureAclTool checkedStep =
    checkedStep
        "install acl for immediate docker socket access"
        ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "acl"]

reportDockerAccessVerified :: IO ()
reportDockerAccessVerified =
    putStrLn
        (dockerLabel ++ ": docker group membership verified and current-session socket ACL ensured")
