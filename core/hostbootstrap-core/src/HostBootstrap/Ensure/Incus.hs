-- | The @ensure incus@ reconciler: the host-provider tool, applicable on
-- **both** apple-silicon and linux (the first cross-substrate reconciler).
--
-- Install-and-verify (see @development_plan_standards.md § L, § U@):
-- @brew install incus@ on apple-silicon; @apt-get install incus@ +
-- @sudo incus admin init --minimal@ on ubuntu-24.04, plus the linux invoking
-- user in @incus-admin@ so the user can reach the daemon socket. A verified
-- no-op when @incus@ is already present; the permission step is still reconciled
-- on linux. The pure 'installSteps' planner is unit-tested.
module HostBootstrap.Ensure.Incus
  ( reconciler,
    installSteps,
    targetIncusAdminUser,
  )
where

import Control.Monad (when)
import Data.List (find)
import Data.Maybe (mapMaybe)
import HostBootstrap.Ensure
  ( InstallStep (..),
    Reconciler (..),
    installAndVerify,
    runTool,
    toolPresent,
  )
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Brew, Incus, Sudo))
import HostBootstrap.Substrate
  ( Substrate,
    SubstrateName (AppleSilicon, LinuxCpu, LinuxGpu),
    isAppleSilicon,
    isLinux,
    substrateName,
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), die)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "incus",
      reconcilerSummary = "Ensure the incus host-provider is installed (apple-silicon and linux)",
      -- The first reconciler applicable on BOTH apple-silicon and linux.
      appliesTo = \sub -> isAppleSilicon sub || isLinux sub,
      requirement = "apple-silicon or linux",
      reconcile = reconcileIncus
    }

reconcileIncus :: HostConfig -> IO ()
reconcileIncus cfg = do
  installAndVerify "incus" (\cfg' -> pure (toolPresent cfg' Incus)) installSteps cfg
  when (isLinux (hcSubstrate cfg)) (ensureIncusAdminGroup cfg)

-- | The substrate-branched install plan: @brew install incus@ on apple-silicon;
-- @apt-get install -y incus@ then @sudo incus admin init --minimal@ on linux.
installSteps :: Substrate -> Either String [InstallStep]
installSteps sub = case substrateName sub of
  AppleSilicon -> Right [InstallStep Brew ["install", "incus"]]
  LinuxCpu -> Right linuxSteps
  LinuxGpu -> Right linuxSteps
  where
    linuxSteps =
      [ InstallStep Sudo ["apt-get", "install", "-y", "incus"],
        InstallStep Sudo ["incus", "admin", "init", "--minimal"]
      ]

ensureIncusAdminGroup :: HostConfig -> IO ()
ensureIncusAdminGroup cfg = do
  env <- getEnvironment
  case targetIncusAdminUser env of
    Nothing ->
      putStrLn "ensure incus: no non-root invoking user detected for incus-admin membership (skipping)"
    Just user -> do
      putStrLn ("ensure incus: ensuring " ++ user ++ " belongs to incus-admin")
      result <- runTool cfg Sudo ["usermod", "-aG", "incus-admin", user]
      case result of
        Right (ExitSuccess, _, _) ->
          putStrLn $
            "ensure incus: incus-admin group membership ensured; "
              ++ "start a new login shell if it was newly added"
        Right (ExitFailure n, _, errOut) ->
          die
            ( "ensure incus: could not add "
                ++ user
                ++ " to incus-admin (exit "
                ++ show n
                ++ ") "
                ++ errOut
            )
        Left err -> die ("ensure incus: " ++ err)

-- | The login user whose future sessions should be allowed to talk to the incus
-- socket. Prefer @SUDO_USER@ so @sudo hostbootstrap ...@ grants the original
-- operator, then fall back to the non-sudo environment. Root itself needs no
-- group grant.
targetIncusAdminUser :: [(String, String)] -> Maybe String
targetIncusAdminUser env = find (/= "root") candidates
  where
    candidates =
      mapMaybe nonEmpty [lookup "SUDO_USER" env, lookup "LOGNAME" env, lookup "USER" env]
    nonEmpty (Just "") = Nothing
    nonEmpty value = value
