-- | The @ensure docker@ reconciler: Docker reachable on every substrate.
module HostBootstrap.Ensure.Docker (reconciler) where

import HostBootstrap.Ensure (Reconciler (..), runTool)
import HostBootstrap.HostTool (HostTool (Docker))
import System.Exit (ExitCode (..), die)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "docker",
      reconcilerSummary = "Ensure the Docker daemon is reachable",
      appliesTo = const True,
      requirement = "all substrates",
      reconcile = \cfg -> do
        result <- runTool cfg Docker ["info"]
        case result of
          Right (ExitSuccess, _, _) -> putStrLn "ensure docker: daemon reachable (no-op)"
          _ ->
            die
              "ensure docker: daemon is not reachable. Start Docker Desktop, Colima, or dockerd and retry."
    }
