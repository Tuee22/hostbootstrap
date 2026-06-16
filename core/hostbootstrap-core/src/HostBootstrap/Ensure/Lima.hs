-- | The @ensure lima@ reconciler: the Lima VM provider on Apple silicon.
--
-- Install-and-verify (see @development_plan_standards.md § L@): @brew install@
-- the @lima@ formula if absent, a verified no-op when @limactl@ is present.
-- The pure 'installSteps' planner is unit-tested.
module HostBootstrap.Ensure.Lima (reconciler, installSteps) where

import HostBootstrap.Ensure
  ( InstallStep (..),
    Reconciler (..),
    installAndVerify,
    toolPresent,
  )
import HostBootstrap.HostTool (HostTool (Brew, Lima))
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
    { reconcilerName = "lima",
      reconcilerSummary = "Ensure the Lima VM provider is installed (Apple silicon)",
      appliesTo = isAppleSilicon,
      requirement = "apple-silicon",
      reconcile = installAndVerify "lima" (\cfg -> pure (toolPresent cfg Lima)) installSteps
    }

-- | The substrate-branched install plan: @brew install lima@.
installSteps :: Substrate -> Either String [InstallStep]
installSteps sub
  | substrateName sub == AppleSilicon =
      Right [InstallStep Brew ["install", "lima"]]
  | otherwise =
      Left ("lima is only applicable on apple-silicon, not " ++ renderSubstrateName (substrateName sub))
