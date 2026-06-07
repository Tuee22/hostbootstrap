-- | The @ensure homebrew@ reconciler: Homebrew present on Apple silicon.
module HostBootstrap.Ensure.Homebrew (reconciler) where

import HostBootstrap.Ensure (Reconciler (..), toolPresent)
import HostBootstrap.HostTool (HostTool (Brew))
import HostBootstrap.Substrate (isAppleSilicon)
import System.Exit (die)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "homebrew",
      reconcilerSummary = "Ensure Homebrew is installed (Apple silicon)",
      appliesTo = isAppleSilicon,
      requirement = "apple-silicon",
      reconcile = \cfg ->
        if toolPresent cfg Brew
          then putStrLn "ensure homebrew: brew present (no-op)"
          else die "ensure homebrew: Homebrew is required. Install from https://brew.sh and retry."
    }
