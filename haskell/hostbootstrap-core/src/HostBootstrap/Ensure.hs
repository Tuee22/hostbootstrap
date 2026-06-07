-- | The @Reconciler@ value type and the generic @ensure <tool>@ subcommand
-- dispatcher.
--
-- A reconciler is an idempotent value: a host-applicability predicate plus a
-- reconcile action (see @development_plan_standards.md § L@). Running a
-- reconciler whose predicate rejects the host fails fast — a one-line
-- diagnostic on stderr and a non-zero exit — before any side effect. The
-- applicability decision ('decide') is pure so it can be tested without
-- exiting the process; 'runReconciler' is the IO wrapper that performs the
-- exit.
module HostBootstrap.Ensure
  ( Reconciler (..),
    decide,
    diagnostic,
    runReconciler,
    runEnsure,
    ensureCommand,
    toolPresent,
    runTool,
  )
where

import Control.Exception (SomeException)
import Control.Exception.Safe (try)
import Data.Maybe (isJust)
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig, resolveMaybe)
import HostBootstrap.HostTool (HostTool, absExePath, toolCommandName)
import HostBootstrap.Substrate (Substrate, detect, renderSubstrateName, substrateName)
import Options.Applicative
import System.Exit (ExitCode (..), die, exitWith)
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

-- | A host-dependency reconciler.
data Reconciler = Reconciler
  { -- | subcommand name, e.g. @"docker"@
    reconcilerName :: String,
    -- | optparse @progDesc@
    reconcilerSummary :: String,
    -- | host-applicability predicate
    appliesTo :: Substrate -> Bool,
    -- | human description of applicable hosts, for the diagnostic
    requirement :: String,
    -- | the idempotent reconcile action
    reconcile :: HostConfig -> IO ()
  }

-- | The one-line diagnostic emitted when a reconciler is run on a host its
-- predicate rejects.
diagnostic :: Reconciler -> Substrate -> String
diagnostic r sub =
  "ensure "
    ++ reconcilerName r
    ++ ": not applicable on "
    ++ renderSubstrateName (substrateName sub)
    ++ " (requires "
    ++ requirement r
    ++ ")"

-- | Decide whether a reconciler applies to a substrate. 'Left' carries the
-- fail-fast diagnostic; 'Right' carries the reconcile action to run. Pure.
decide :: Reconciler -> Substrate -> Either String (HostConfig -> IO ())
decide r sub
  | appliesTo r sub = Right (reconcile r)
  | otherwise = Left (diagnostic r sub)

-- | Run a reconciler against a resolved host configuration. On the wrong host it
-- prints the diagnostic to stderr and exits non-zero before any side effect; on
-- the right host it runs the (idempotent) reconcile action.
runReconciler :: Reconciler -> HostConfig -> IO ()
runReconciler r cfg = case decide r (hcSubstrate cfg) of
  Left msg -> hPutStrLn stderr msg >> exitWith (ExitFailure 1)
  Right act -> act cfg

-- | Detect the substrate, resolve the host configuration, and run a reconciler.
-- The action wired behind each @ensure <tool>@ subcommand.
runEnsure :: Reconciler -> IO ()
runEnsure r = do
  detected <- detect
  case detected of
    Left err -> die err
    Right sub -> do
      cfg <- buildHostConfig sub
      runReconciler r cfg

-- | The generic @ensure@ command group, built from a list of reconcilers. The
-- caller (the core command tree) supplies the concrete reconcilers.
ensureCommand :: [Reconciler] -> Mod CommandFields (IO ())
ensureCommand reconcilers =
  command
    "ensure"
    ( info
        (hsubparser (mconcat (map toSub reconcilers)))
        (progDesc "Ensure a host dependency is present (idempotent; fails fast on the wrong host)")
    )
  where
    toSub r =
      command
        (reconcilerName r)
        (info (pure (runEnsure r)) (progDesc (reconcilerSummary r)))

-- | Whether a host tool is resolved in the configuration.
toolPresent :: HostConfig -> HostTool -> Bool
toolPresent cfg t = isJust (resolveMaybe cfg t)

-- | Run a resolved host tool through its absolute path. Returns 'Left' when the
-- tool is not resolved or the exec fails; the reconcile actions use this rather
-- than a @$PATH@-resolved bare name.
runTool :: HostConfig -> HostTool -> [String] -> IO (Either String (ExitCode, String, String))
runTool cfg t args = case resolveMaybe cfg t of
  Nothing -> pure (Left (toolCommandName t ++ " not found on this host"))
  Just exe -> do
    result <- try (readProcessWithExitCode (absExePath exe) args "")
    pure $ case (result :: Either SomeException (ExitCode, String, String)) of
      Right ok -> Right ok
      Left err -> Left ("could not exec " ++ absExePath exe ++ ": " ++ show err)
