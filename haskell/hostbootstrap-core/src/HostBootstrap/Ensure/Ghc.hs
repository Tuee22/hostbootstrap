-- | The @ensure ghc@ reconciler: the host GHC toolchain for native Apple builds.
module HostBootstrap.Ensure.Ghc (reconciler) where

import HostBootstrap.Ensure (Reconciler (..), toolPresent)
import HostBootstrap.HostTool (HostTool (Ghc, Ghcup))
import HostBootstrap.Substrate (isAppleSilicon)
import System.Exit (die)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "ghc",
      reconcilerSummary = "Ensure the host GHC toolchain (Apple silicon native build)",
      appliesTo = isAppleSilicon,
      requirement = "apple-silicon",
      reconcile = \cfg ->
        if toolPresent cfg Ghc
          then putStrLn "ensure ghc: host GHC present (no-op)"
          else
            if toolPresent cfg Ghcup
              then die "ensure ghc: ghcup present but GHC not installed. Run `ghcup install ghc`."
              else die "ensure ghc: host GHC is required. Run `brew install ghcup` then `ghcup install ghc`."
    }
