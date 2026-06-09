-- | The @ensure tart@ reconciler: the build-only Tart VM tool on Apple silicon.
--
-- Install-and-verify (see @development_plan_standards.md § L@): @brew install@
-- the @cirruslabs/cli/tart@ formula if absent, a verified no-op when present.
-- The pure 'installSteps' planner is unit-tested.
module HostBootstrap.Ensure.Tart (reconciler, installSteps) where

import HostBootstrap.Ensure
  ( InstallStep (..),
    Reconciler (..),
    installAndVerify,
    toolPresent,
  )
import HostBootstrap.HostTool (HostTool (Brew, Tart))
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
    { reconcilerName = "tart",
      reconcilerSummary = "Ensure the Tart build VM tool is installed (Apple silicon, build-only)",
      appliesTo = isAppleSilicon,
      requirement = "apple-silicon",
      reconcile = installAndVerify "tart" (\cfg -> pure (toolPresent cfg Tart)) installSteps
    }

-- | The substrate-branched install plan: @brew install cirruslabs/cli/tart@.
installSteps :: Substrate -> Either String [InstallStep]
installSteps sub
  | substrateName sub == AppleSilicon =
      Right [InstallStep Brew ["install", "cirruslabs/cli/tart"]]
  | otherwise =
      Left ("tart is only applicable on apple-silicon, not " ++ renderSubstrateName (substrateName sub))
