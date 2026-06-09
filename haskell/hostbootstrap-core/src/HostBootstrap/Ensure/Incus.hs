-- | The @ensure incus@ reconciler: the host-provider tool, applicable on
-- **both** apple-silicon and linux (the first cross-substrate reconciler).
--
-- Install-and-verify (see @development_plan_standards.md § L, § U@):
-- @brew install incus@ on apple-silicon; @apt-get install incus@ +
-- @incus admin init --minimal@ on ubuntu-24.04. A verified no-op when @incus@ is
-- already present. The pure 'installSteps' planner is unit-tested.
module HostBootstrap.Ensure.Incus (reconciler, installSteps) where

import HostBootstrap.Ensure
  ( InstallStep (..),
    Reconciler (..),
    installAndVerify,
    toolPresent,
  )
import HostBootstrap.HostTool (HostTool (Brew, Incus, Sudo))
import HostBootstrap.Substrate
  ( Substrate,
    SubstrateName (AppleSilicon, LinuxCpu, LinuxGpu),
    isAppleSilicon,
    isLinux,
    substrateName,
  )

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "incus",
      reconcilerSummary = "Ensure the incus host-provider is installed (apple-silicon and linux)",
      -- The first reconciler applicable on BOTH apple-silicon and linux.
      appliesTo = \sub -> isAppleSilicon sub || isLinux sub,
      requirement = "apple-silicon or linux",
      reconcile = installAndVerify "incus" (\cfg -> pure (toolPresent cfg Incus)) installSteps
    }

-- | The substrate-branched install plan: @brew install incus@ on apple-silicon;
-- @apt-get install -y incus@ then @incus admin init --minimal@ on linux.
installSteps :: Substrate -> Either String [InstallStep]
installSteps sub = case substrateName sub of
  AppleSilicon -> Right [InstallStep Brew ["install", "incus"]]
  LinuxCpu -> Right linuxSteps
  LinuxGpu -> Right linuxSteps
  where
    linuxSteps =
      [ InstallStep Sudo ["apt-get", "install", "-y", "incus"],
        InstallStep Incus ["admin", "init", "--minimal"]
      ]
