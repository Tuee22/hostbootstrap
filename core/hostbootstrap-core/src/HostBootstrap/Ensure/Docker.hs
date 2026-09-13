{- | The @ensure docker@ reconciler: a reachable Docker daemon on every substrate.

Install-and-verify (see @development_plan_standards.md § L@): on Linux,
@apt-get install docker.io docker-buildx@, enable the daemon, grant the invoking non-root
user membership in @docker@, and apply a user ACL to the live socket so the
current process can use Docker before a relogin. On Apple silicon Docker is
provided by the prepared per-project Colima provider wall, so this
config-free planner refuses rather than attempting a host-package install.
The pure
'installSteps' planner and target-user selector are unit-tested.
-}
module HostBootstrap.Ensure.Docker (reconciler, installSteps) where

import Control.Monad (when)
import HostBootstrap.Ensure (
    grantSocketAccess,
    requireSudoStep,
    withInvokingGroupMember,
    FramePlan (InstallHere, ProvidedElsewhere),
    InstallStep (..),
    Reconciler (..),
    appleRow,
    frameTable,
    installAndVerify,
    linuxRow,
    reconcilerInstallSteps,
    runTool,
    windowsRow,
 )
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Docker, Sudo))
import HostBootstrap.Substrate (Substrate, isLinux)
import System.Exit (ExitCode (..))

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
                        [ InstallStep Sudo ["apt-get", "install", "-y", "docker.io", "docker-buildx", "acl"]
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
follow-up group check verifies future unprivileged sessions explicitly.
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

{- | Docker asks one question the Incus row does not: whether a /future/ login
would work. Group membership that the daemon has not picked up is a reconciler
that reported success and left the next session broken.
-}
verifyDockerGroup :: HostConfig -> String -> IO ()
verifyDockerGroup cfg user = do
    requireSudoStep
        cfg
        dockerLabel
        ("verify docker group membership for " ++ user)
        ["-u", user, "sg", "docker", "-c", "docker info >/dev/null"]
    ensureCurrentSessionSocketAccess cfg user

ensureCurrentSessionSocketAccess :: HostConfig -> String -> IO ()
ensureCurrentSessionSocketAccess cfg user = do
    direct <- dockerInfo cfg
    if direct
        then reportDockerAccessVerified
        else do
            ensureAclTool cfg
            grantSocketAccess cfg dockerLabel dockerSocketPath user
            reportDockerAccessVerified

ensureAclTool :: HostConfig -> IO ()
ensureAclTool cfg =
    requireSudoStep
        cfg
        dockerLabel
        "install acl for immediate docker socket access"
        ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "acl"]

reportDockerAccessVerified :: IO ()
reportDockerAccessVerified =
    putStrLn
        (dockerLabel ++ ": docker group membership verified and current-session socket ACL ensured")

