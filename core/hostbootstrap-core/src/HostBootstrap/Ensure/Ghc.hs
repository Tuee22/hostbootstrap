-- | The @ensure ghc@ reconciler: the host GHC toolchain for native Apple builds.
--
-- Install-and-verify (see @development_plan_standards.md § L@): @brew install
-- ghcup@ then @ghcup install ghc@ if GHC is absent, a verified no-op when the
-- host GHC is present. The pure 'installSteps' planner is unit-tested.
module HostBootstrap.Ensure.Ghc (reconciler, installSteps) where

import HostBootstrap.Ensure
  ( InstallStep (..),
    Reconciler (..),
    installAndVerify,
    toolPresent,
  )
import HostBootstrap.HostTool (HostTool (Brew, Ghc, Ghcup))
import HostBootstrap.Substrate
  ( Substrate,
    SubstrateName (AppleSilicon),
    isAppleSilicon,
    renderSubstrateName,
    substrateName,
  )

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "ghc",
      reconcilerSummary = "Ensure the host GHC toolchain (Apple silicon native build)",
      appliesTo = isAppleSilicon,
      requirement = "apple-silicon",
      reconcile = installAndVerify "ghc" (\cfg -> pure (toolPresent cfg Ghc)) installSteps
    }

-- | The substrate-branched install plan: @brew install ghcup@ then
-- @ghcup install ghc@. The tools are re-resolved after each step, so @ghcup@ is
-- discoverable for the second step once @brew@ has laid it down.
installSteps :: Substrate -> Either String [InstallStep]
installSteps sub
  | substrateName sub == AppleSilicon =
      Right
        [ InstallStep Brew ["install", "ghcup"],
          InstallStep Ghcup ["install", "ghc"]
        ]
  | otherwise =
      Left ("ghc host-toolchain install is only applicable on apple-silicon, not " ++ renderSubstrateName (substrateName sub))
