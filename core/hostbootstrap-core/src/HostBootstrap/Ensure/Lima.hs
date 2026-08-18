-- | The @ensure lima@ reconciler: the Lima VM provider on Apple silicon.
--
-- Install-and-verify (see @development_plan_standards.md § L@): @brew install@
-- the @lima@ formula if absent, a verified no-op when @limactl@ is present.
-- The pure 'installSteps' planner is unit-tested.
module HostBootstrap.Ensure.Lima (reconciler, installSteps) where

import HostBootstrap.Ensure
  ( FramePlan (InstallHere),
    InstallStep (..),
    Reconciler (..),
    appleRow,
    frameTable,
    installAndVerify,
    reconcilerInstallSteps,
    toolPresent,
  )
import HostBootstrap.HostTool (HostTool (Brew, Lima))
import HostBootstrap.Substrate (Substrate)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "lima",
      reconcilerSummary = "Ensure the Lima VM provider is installed (Apple silicon)",
      -- One row: @brew install lima@.
      reconcilerFrames =
        frameTable [appleRow (InstallHere [InstallStep Brew ["install", "lima"]])],
      reconcile = installAndVerify "lima" (\cfg -> pure (toolPresent cfg Lima)) installSteps
    }

installSteps :: Substrate -> Either String [InstallStep]
installSteps = reconcilerInstallSteps reconciler
