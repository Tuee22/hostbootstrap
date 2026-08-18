-- | The @Reconciler@ value type and runner used by @ensure-*@ chain steps.
--
-- A reconciler is a frame table plus a reconcile action (see
-- @development_plan_standards.md § L@ and @§ LL@). Implementations are
-- probe-first; their no-op guarantee is only as strong as the probe or
-- package-manager no-op path. Running a reconciler on a host it has no row for
-- fails fast — a one-line diagnostic on stderr and a non-zero exit — before any
-- side effect. The applicability decision ('decide') is pure so it can be
-- tested without exiting the process; 'runReconciler' is the IO wrapper that
-- performs the exit.
--
-- A reconciler is a __row__, not a module of parallel logic. Which hosts it
-- applies to, how those hosts are described in a diagnostic, and what it
-- installs on each are three views of one 'FrameTable' rather than three fields
-- that can disagree — and they did disagree: a reconciler could claim to apply
-- everywhere while its own plan refused two of the five tags, so the wrong-host
-- answer arrived as an install failure instead of as a decision.
module HostBootstrap.Ensure
  ( -- * The reconciler
    Reconciler (..),
    appliesTo,
    requirement,
    decide,
    diagnostic,
    runReconciler,
    runEnsure,

    -- * The frame table a reconciler is a row over
    FrameTable,
    FrameRow,
    FramePlan (..),
    frameTable,
    linuxRow,
    linuxGpuRow,
    appleRow,
    windowsRow,
    windowsGpuRow,
    tableRows,
    tableApplies,
    tableRequirement,
    reconcilerInstallSteps,

    -- * Tools and install steps
    toolPresent,
    runTool,
    runToolWithStdin,
    InstallStep (..),
    installAndVerify,
    installAndVerifyWith,
  )
where

import Control.Monad (foldM)
import Data.Char (toLower)
import Data.List (find, intercalate, isInfixOf)
import Data.Maybe (isJust)
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (capturedTriple)
import HostBootstrap.Effect.Vocabulary (hostCommand, withCommandStdin)
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig, resolveMaybe)
import HostBootstrap.HostTool (HostTool (Winget, Wsl), toolCommandName)
import HostBootstrap.Substrate
  ( HostFrame (AppleFrame, LinuxFrame, WindowsFrame),
    Substrate,
    allHostFrames,
    detect,
    hasGpu,
    renderHostFrame,
    renderSubstrateName,
    substrateFrame,
    substrateName,
  )
import System.Exit (ExitCode (..), die, exitWith)
import System.IO (hPutStrLn, stderr)

-- | A host-dependency reconciler.
data Reconciler = Reconciler
  { -- | reconciler name, e.g. @"docker"@ (the @ensure-*@ chain-step label)
    reconcilerName :: String,
    -- | one-line human summary of what the reconciler ensures
    reconcilerSummary :: String,
    -- | the frames this reconciler is a row over, and what each contributes
    reconcilerFrames :: FrameTable,
    -- | the idempotent reconcile action
    reconcile :: HostConfig -> IO ()
  }

-- | Whether the reconciler has a row for this host. Derived, never declared.
appliesTo :: Reconciler -> Substrate -> Bool
appliesTo = tableApplies . reconcilerFrames

-- | How the reconciler's applicable hosts are described in a diagnostic.
-- Derived from the same rows the predicate reads, so the two cannot disagree.
requirement :: Reconciler -> String
requirement = tableRequirement . reconcilerFrames

-- | The reconciler's install plan for a host: its row's own steps, or the one
-- derived refusal. Every reconciler's @installSteps@ is this function applied
-- to its own record, so no module writes a wrong-host message of its own.
reconcilerInstallSteps :: Reconciler -> Substrate -> Either String [InstallStep]
reconcilerInstallSteps r sub = case frameRowFor (reconcilerFrames r) sub of
  Nothing -> Left (diagnostic r sub)
  Just row -> case rowPlan row of
    InstallHere steps -> Right steps
    ProvidedElsewhere instruction -> Left instruction

-- | The one-line diagnostic emitted when a reconciler is run on a host it has
-- no row for. It is also the plan's refusal, so a caller cannot be told two
-- different things about the same absent row.
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

-- ---------------------------------------------------------------------------
-- The frame table (§ LL)
-- ---------------------------------------------------------------------------

-- | What a reconciler's row contributes in the frame it is written for.
data FramePlan
  = -- | the row installs the dependency itself, with these steps
    InstallHere [InstallStep]
  | -- | the row applies — the dependency is probed here — but this frame does
    -- not install it, and the string says who does, or what the operator must
    -- do instead
    ProvidedElsewhere String
  deriving (Eq, Show)

-- | One row: a frame, what the row requires of it, and the row's plan there.
data FrameRow = FrameRow
  { rowFrame :: HostFrame,
    rowRequiresNvidia :: Bool,
    rowPlan :: FramePlan
  }
  deriving (Eq, Show)

-- | The frames a reconciler is a row over. An absent row is "not applicable",
-- which is a decision rather than a refusal a caller has to read out of a
-- failed install.
newtype FrameTable = FrameTable {tableRows :: [FrameRow]}
  deriving (Eq, Show)

-- | Build a table, ordering accelerator rows first so that a table carrying
-- both a general and an accelerator row for one frame selects the specific one
-- rather than whichever happened to be written first.
frameTable :: [FrameRow] -> FrameTable
frameTable rows =
  FrameTable (filter rowRequiresNvidia rows ++ filter (not . rowRequiresNvidia) rows)

linuxRow :: FramePlan -> FrameRow
linuxRow = FrameRow LinuxFrame False

linuxGpuRow :: FramePlan -> FrameRow
linuxGpuRow = FrameRow LinuxFrame True

appleRow :: FramePlan -> FrameRow
appleRow = FrameRow AppleFrame False

windowsRow :: FramePlan -> FrameRow
windowsRow = FrameRow WindowsFrame False

windowsGpuRow :: FramePlan -> FrameRow
windowsGpuRow = FrameRow WindowsFrame True

-- | The row that governs this host, if the table has one.
frameRowFor :: FrameTable -> Substrate -> Maybe FrameRow
frameRowFor (FrameTable rows) sub = find governs rows
  where
    governs row =
      rowFrame row == substrateFrame sub
        && (not (rowRequiresNvidia row) || hasGpu sub)

tableApplies :: FrameTable -> Substrate -> Bool
tableApplies table = isJust . frameRowFor table

-- | Render the applicable hosts from the rows themselves.
--
-- A table with a general row for every frame reads "all substrates" rather than
-- the three names spelled out, because that is what a reader of the diagnostic
-- needs to know.
tableRequirement :: FrameTable -> String
tableRequirement (FrameTable rows)
  | universal = "all substrates"
  | otherwise = intercalate " or " (map renderRow rows)
  where
    universal =
      not (any rowRequiresNvidia rows)
        && all (`elem` map rowFrame rows) allHostFrames
    renderRow row
      | rowRequiresNvidia row = renderHostFrame (rowFrame row) ++ "-gpu"
      | otherwise = renderHostFrame (rowFrame row)

-- | Run a reconciler against a resolved host configuration. On the wrong host it
-- prints the diagnostic to stderr and exits non-zero before any side effect; on
-- the right host it runs the (idempotent) reconcile action.
runReconciler :: Reconciler -> HostConfig -> IO ()
runReconciler r cfg = case decide r (hcSubstrate cfg) of
  Left msg -> hPutStrLn stderr msg >> exitWith (ExitFailure 1)
  Right act -> act cfg

-- | Detect the substrate, resolve the host configuration, and run a reconciler.
-- Chain steps and project-owned action seams call this directly.
runEnsure :: Reconciler -> IO ()
runEnsure r = do
  detected <- detect
  case detected of
    Left err -> die err
    Right sub -> do
      cfg <- buildHostConfig sub
      runReconciler r cfg

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
installAndVerify =
  installAndVerifyWith
    runTool
    (buildHostConfig . hcSubstrate)

-- | Injectable form of 'installAndVerify'. Production reconciliation uses the
-- real resolved-tool runner and rebuilds the host configuration after every
-- successful step; tests and embedders can supply those two effects while the
-- probe-first, refresh-between-steps, and verify-last control flow remains the
-- production implementation.
installAndVerifyWith ::
  -- | resolved-tool runner
  (HostConfig -> HostTool -> [String] -> IO (Either String (ExitCode, String, String))) ->
  -- | refresh the resolved host configuration after a successful step
  (HostConfig -> IO HostConfig) ->
  -- | reconciler name (for messages)
  String ->
  -- | probe: is the dependency satisfied?
  (HostConfig -> IO Bool) ->
  -- | substrate-branched install plan
  (Substrate -> Either String [InstallStep]) ->
  HostConfig ->
  IO ()
installAndVerifyWith runInstallStep refreshConfig name probe plan cfg0 = do
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
      result <- runInstallStep cfg tool args
      case result of
        Right (ExitSuccess, out, errOut)
          | wslNeedsReboot tool (out ++ errOut) ->
              die ("ensure " ++ name ++ ": host reboot required after WSL2 install; reboot and retry")
          | otherwise -> refreshConfig cfg
        Right (ExitFailure n, out, errOut)
          | wslNeedsReboot tool (out ++ errOut) ->
              die ("ensure " ++ name ++ ": host reboot required after WSL2 install; reboot and retry")
          | wslInstallNeedsReboot tool args n ->
              die ("ensure " ++ name ++ ": host reboot required after WSL2 install; reboot and retry")
          | wingetAlreadyInstalled tool args (out ++ errOut) -> refreshConfig cfg
          | otherwise ->
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

    wingetAlreadyInstalled tool args output =
      tool == Winget
        && take 1 args == ["install"]
        && ( "Found an existing package already installed" `isInfixOf` output
               || "No available upgrade found" `isInfixOf` output
           )

    wslNeedsReboot tool output =
      tool == Wsl
        && let lower = map toLower output
            in "reboot" `isInfixOf` lower || "restart" `isInfixOf` lower

    wslInstallNeedsReboot tool args exitCode =
      tool == Wsl
        && exitCode == -1
        && "--install" `elem` args

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
runToolWithStdin cfg t args input =
  fmap capturedTriple <$> interpretHostCommand cfg (withCommandStdin input (hostCommand t args))
