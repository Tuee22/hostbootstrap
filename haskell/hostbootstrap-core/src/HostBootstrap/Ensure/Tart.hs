-- | The @ensure tart@ reconciler: the build-only Tart VM on Apple silicon.
module HostBootstrap.Ensure.Tart (reconciler) where

import HostBootstrap.Ensure (Reconciler (..), toolPresent)
import HostBootstrap.HostTool (HostTool (Tart))
import HostBootstrap.Substrate (isAppleSilicon)
import System.Exit (die)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "tart",
      reconcilerSummary = "Ensure the Tart build VM tool is installed (Apple silicon, build-only)",
      appliesTo = isAppleSilicon,
      requirement = "apple-silicon",
      reconcile = \cfg ->
        if toolPresent cfg Tart
          then putStrLn "ensure tart: tart present (no-op)"
          else die "ensure tart: Tart is required. Run `brew install cirruslabs/cli/tart` and retry."
    }
