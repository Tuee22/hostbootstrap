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
    ensureCommandWith,
    toolPresent,
    runTool,
    runToolWithStdin,
    InstallStep (..),
    installAndVerify,
  )
where

import Control.Exception (SomeException)
import Control.Exception.Safe (try)
import Control.Monad (foldM)
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
ensureCommand = ensureCommandWith id

-- | Like 'ensureCommand', with a caller-supplied action wrapper. Core uses this
-- to run the binary-context gate before dispatching a reconciler while tests and
-- library callers can keep the plain command surface.
ensureCommandWith :: (IO () -> IO ()) -> [Reconciler] -> Mod CommandFields (IO ())
ensureCommandWith wrap reconcilers =
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
        (info (pure (wrap (runEnsure r))) (progDesc (reconcilerSummary r)))

-- | A single install step: a resolved host tool run with arguments. The step is
-- a pure, inspectable value so the substrate-branched install plan can be
-- unit-tested without invoking the package manager.
data InstallStep = InstallStep
  { stepTool :: HostTool,
    stepArgs :: [String]
  }
  deriving (Eq, Show)

-- | Probe-first install-and-verify (see @development_plan_standards.md § L@). If
-- the dependency is already satisfied the reconciler is a verified no-op;
-- otherwise it runs the substrate-branched install plan and re-verifies, failing
-- fast with a one-line diagnostic if the dependency is still missing. Tools are
-- re-resolved after each step so a freshly installed tool (e.g. @ghcup@ just laid
-- down by @brew@) is discoverable by the next step and the verify probe. The
-- @plan@ argument is pure and unit-tested per reconciler; this driver is the IO
-- shell exercised during real bootstrap runs.
installAndVerify ::
  -- | reconciler name (for messages)
  String ->
  -- | probe: is the dependency satisfied?
  (HostConfig -> IO Bool) ->
  -- | substrate-branched install plan
  (Substrate -> Either String [InstallStep]) ->
  HostConfig ->
  IO ()
installAndVerify name probe plan cfg0 = do
  satisfied <- probe cfg0
  if satisfied
    then putStrLn ("ensure " ++ name ++ ": present (no-op)")
    else case plan (hcSubstrate cfg0) of
      Left err -> die ("ensure " ++ name ++ ": " ++ err)
      Right steps -> do
        putStrLn ("ensure " ++ name ++ ": installing (" ++ show (length steps) ++ " step(s))")
        cfg1 <- foldM runStep cfg0 steps
        ok <- probe cfg1
        if ok
          then putStrLn ("ensure " ++ name ++ ": installed and verified")
          else die ("ensure " ++ name ++ ": still not satisfied after install; install manually and retry")
  where
    runStep cfg (InstallStep tool args) = do
      result <- runTool cfg tool args
      case result of
        Right (ExitSuccess, _, _) -> buildHostConfig (hcSubstrate cfg)
        Right (ExitFailure n, _, errOut) ->
          die
            ( "ensure "
                ++ name
                ++ ": install step `"
                ++ toolCommandName tool
                ++ " "
                ++ unwords args
                ++ "` failed (exit "
                ++ show n
                ++ ") "
                ++ errOut
            )
        Left err -> die ("ensure " ++ name ++ ": " ++ err)

-- | Whether a host tool is resolved in the configuration.
toolPresent :: HostConfig -> HostTool -> Bool
toolPresent cfg t = isJust (resolveMaybe cfg t)

-- | Run a resolved host tool through its absolute path. Returns 'Left' when the
-- tool is not resolved or the exec fails; the reconcile actions use this rather
-- than a @$PATH@-resolved bare name.
runTool :: HostConfig -> HostTool -> [String] -> IO (Either String (ExitCode, String, String))
runTool cfg t args = runToolWithStdin cfg t args ""

-- | Like 'runTool', but feed @stdin@ to the process. Used to forward a secret
-- (a Docker Hub credential) on @stdin@ rather than in @argv@, so it never appears
-- in a process listing. The @stdin@ string is the only channel the secret
-- travels on, and it is consumed by the wrapped command (see
-- 'HostBootstrap.Registry.dockerAuthStdinWrapper').
runToolWithStdin :: HostConfig -> HostTool -> [String] -> String -> IO (Either String (ExitCode, String, String))
runToolWithStdin cfg t args input = case resolveMaybe cfg t of
  Nothing -> pure (Left (toolCommandName t ++ " not found on this host"))
  Just exe -> do
    result <- try (readProcessWithExitCode (absExePath exe) args input)
    pure $ case (result :: Either SomeException (ExitCode, String, String)) of
      Right ok -> Right ok
      Left err -> Left ("could not exec " ++ absExePath exe ++ ": " ++ show err)
