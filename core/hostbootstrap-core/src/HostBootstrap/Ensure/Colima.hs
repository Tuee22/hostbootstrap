-- | The @ensure colima@ reconciler: the per-project Colima VM on Apple silicon.
--
-- Install-and-verify (see @development_plan_standards.md § L@): @brew install@
-- the @colima@ formula if absent and start the VM, a verified no-op when it is
-- already installed and running. The pure 'installSteps' planner is unit-tested.
module HostBootstrap.Ensure.Colima (reconciler, installSteps) where

import HostBootstrap.Ensure
  ( InstallStep (..),
    Reconciler (..),
    installAndVerify,
    runTool,
    toolPresent,
  )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Brew, Colima))
import HostBootstrap.Substrate
  ( Substrate,
    SubstrateName (AppleSilicon),
    isAppleSilicon,
    renderSubstrateName,
    substrateName,
  )
import System.Exit (ExitCode (..))

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "colima",
      reconcilerSummary = "Ensure the per-project Colima VM is installed and running (Apple silicon)",
      appliesTo = isAppleSilicon,
      requirement = "apple-silicon",
      reconcile = installAndVerify "colima" satisfied installSteps
    }

-- | Colima is satisfied when it is installed and @colima status@ reports the VM
-- is running.
satisfied :: HostConfig -> IO Bool
satisfied cfg
  | not (toolPresent cfg Colima) = pure False
  | otherwise = do
      status <- runTool cfg Colima ["status"]
      pure $ case status of
        Right (ExitSuccess, _, _) -> True
        _ -> False

-- | The substrate-branched install plan: @brew install colima@ then
-- @colima start@. @brew install@ is idempotent (a no-op when already installed).
installSteps :: Substrate -> Either String [InstallStep]
installSteps sub
  | substrateName sub == AppleSilicon =
      Right
        [ InstallStep Brew ["install", "colima"],
          InstallStep Colima ["start"]
        ]
  | otherwise =
      Left ("colima is only applicable on apple-silicon, not " ++ renderSubstrateName (substrateName sub))
