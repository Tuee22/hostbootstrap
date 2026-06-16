-- | The @ensure docker@ reconciler: a reachable Docker daemon on every substrate.
--
-- Install-and-verify (see @development_plan_standards.md § L@): on Linux,
-- @apt-get install docker.io@, enable the daemon, grant the invoking non-root
-- user membership in @docker@, and apply a user ACL to the live socket so the
-- current process can use Docker before a relogin. On Apple silicon Docker is
-- provided by the per-project Colima VM, so the planner defers to @ensure
-- colima@ rather than attempting a host-package install. The pure
-- 'installSteps' planner and target-user selector are unit-tested.
module HostBootstrap.Ensure.Docker (reconciler, installSteps, targetDockerUser) where

import Control.Monad (when)
import Data.List (find)
import Data.Maybe (mapMaybe)
import HostBootstrap.Ensure
  ( InstallStep (..),
    Reconciler (..),
    installAndVerify,
    runTool,
  )
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Docker, Sudo))
import HostBootstrap.Substrate
  ( Substrate,
    SubstrateName (AppleSilicon, LinuxCpu, LinuxGpu),
    isLinux,
    substrateName,
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), die)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "docker",
      reconcilerSummary = "Ensure the Docker daemon is installed and reachable",
      appliesTo = const True,
      requirement = "all substrates",
      reconcile = reconcileDocker
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

-- | Docker is satisfied when the daemon is reachable. On Linux the immediate
-- Haskell process cannot observe group membership added during this run, so the
-- install probe accepts @sudo docker info@ for daemon reachability; the
-- follow-up group check verifies future unprivileged sessions explicitly.
daemonReachable :: HostConfig -> IO Bool
daemonReachable cfg
  | isLinux (hcSubstrate cfg) = do
      direct <- dockerInfo cfg
      if direct
        then pure True
        else sudoDockerInfo cfg
  | otherwise = dockerInfo cfg

sudoDockerInfo :: HostConfig -> IO Bool
sudoDockerInfo cfg = do
  result <- runTool cfg Sudo ["docker", "info"]
  pure $ case result of
    Right (ExitSuccess, _, _) -> True
    _ -> False

-- | The substrate-branched install plan. On Linux, @apt-get install docker.io@
-- and enable the daemon. On Apple silicon, Docker is the per-project Colima VM's
-- responsibility, so defer to @ensure colima@.
installSteps :: Substrate -> Either String [InstallStep]
installSteps sub = case substrateName sub of
  AppleSilicon ->
    Left "on Apple silicon Docker is provided by the per-project Colima VM; run `ensure colima` first"
  LinuxCpu -> Right linuxSteps
  LinuxGpu -> Right linuxSteps
  where
    linuxSteps =
      [ InstallStep Sudo ["apt-get", "install", "-y", "docker.io", "acl"],
        InstallStep Sudo ["systemctl", "enable", "--now", "docker"]
      ]

ensureDockerGroup :: HostConfig -> IO ()
ensureDockerGroup cfg = do
  env <- getEnvironment
  case targetDockerUser env of
    Nothing ->
      putStrLn "ensure docker: no non-root invoking user detected for docker group membership (skipping)"
    Just user -> do
      putStrLn ("ensure docker: ensuring " ++ user ++ " belongs to docker")
      result <- runTool cfg Sudo ["usermod", "-aG", "docker", user]
      case result of
        Right (ExitSuccess, _, _) -> verifyDockerGroup cfg user
        Right (ExitFailure n, _, errOut) ->
          die
            ( "ensure docker: could not add "
                ++ user
                ++ " to docker (exit "
                ++ show n
                ++ ") "
                ++ errOut
            )
        Left err -> die ("ensure docker: " ++ err)

verifyDockerGroup :: HostConfig -> String -> IO ()
verifyDockerGroup cfg user = do
  future <- runTool cfg Sudo ["-u", user, "sg", "docker", "-c", "docker info >/dev/null"]
  case future of
    Right (ExitSuccess, _, _) -> ensureCurrentSessionSocketAccess cfg user
    Right (ExitFailure n, _, errOut) ->
      die
        ( "ensure docker: docker group verification for "
            ++ user
            ++ " failed (exit "
            ++ show n
            ++ ") "
            ++ errOut
        )
    Left err -> die ("ensure docker: " ++ err)

ensureCurrentSessionSocketAccess :: HostConfig -> String -> IO ()
ensureCurrentSessionSocketAccess cfg user = do
  direct <- dockerInfo cfg
  if direct
    then reportDockerAccessVerified
    else do
      ensureAclTool cfg
      grant <- runTool cfg Sudo ["setfacl", "-m", "u:" ++ user ++ ":rw", "/var/run/docker.sock"]
      case grant of
        Right (ExitSuccess, _, _) -> reportDockerAccessVerified
        Right (ExitFailure n, _, errOut) ->
          die
            ( "ensure docker: could not grant "
                ++ user
                ++ " immediate access to /var/run/docker.sock (exit "
                ++ show n
                ++ ") "
                ++ errOut
            )
        Left err -> die ("ensure docker: " ++ err)

ensureAclTool :: HostConfig -> IO ()
ensureAclTool cfg = do
  result <- runTool cfg Sudo ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "acl"]
  case result of
    Right (ExitSuccess, _, _) ->
      pure ()
    Right (ExitFailure n, _, errOut) ->
      die
        ( "ensure docker: could not install acl for immediate docker socket access (exit "
            ++ show n
            ++ ") "
            ++ errOut
        )
    Left err -> die ("ensure docker: " ++ err)

reportDockerAccessVerified :: IO ()
reportDockerAccessVerified =
  putStrLn $
    "ensure docker: docker group membership verified and current-session socket ACL ensured"

-- | The login user whose future sessions should be allowed to talk to the
-- docker socket. Prefer @SUDO_USER@ so @sudo hostbootstrap ...@ grants the
-- original operator, then fall back to the non-sudo environment. Root itself
-- needs no group grant.
targetDockerUser :: [(String, String)] -> Maybe String
targetDockerUser env = find (/= "root") candidates
  where
    candidates =
      mapMaybe nonEmpty [lookup "SUDO_USER" env, lookup "LOGNAME" env, lookup "USER" env]
    nonEmpty (Just "") = Nothing
    nonEmpty value = value
