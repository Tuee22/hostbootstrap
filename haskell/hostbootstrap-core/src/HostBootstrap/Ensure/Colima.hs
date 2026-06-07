-- | The @ensure colima@ reconciler: the per-project Colima VM on Apple silicon.
module HostBootstrap.Ensure.Colima (reconciler) where

import HostBootstrap.Ensure (Reconciler (..), runTool, toolPresent)
import HostBootstrap.HostTool (HostTool (Colima))
import HostBootstrap.Substrate (isAppleSilicon)
import System.Exit (ExitCode (..), die)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "colima",
      reconcilerSummary = "Ensure the per-project Colima VM is running (Apple silicon)",
      appliesTo = isAppleSilicon,
      requirement = "apple-silicon",
      reconcile = \cfg ->
        if not (toolPresent cfg Colima)
          then die "ensure colima: colima not installed. Run `ensure homebrew` then `brew install colima`."
          else do
            status <- runTool cfg Colima ["status"]
            case status of
              Right (ExitSuccess, _, _) -> putStrLn "ensure colima: VM running (no-op)"
              _ -> do
                started <- runTool cfg Colima ["start"]
                case started of
                  Right (ExitSuccess, _, _) -> putStrLn "ensure colima: VM started"
                  _ -> die "ensure colima: failed to start the Colima VM."
    }
