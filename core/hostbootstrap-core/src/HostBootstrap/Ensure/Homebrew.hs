-- | The @ensure homebrew@ reconciler: Homebrew present on Apple silicon.
--
-- Homebrew is the host toolchain root, so it cannot be installed through a
-- resolved host tool (there is no package manager to bootstrap it). The Python
-- bootstrapper installs it pre-binary (see @development_plan_standards.md § N@);
-- this reconciler is a verified no-op when @brew@ is present and fails fast with
-- the install instruction when it is absent. The pure 'installSteps' planner —
-- which has no resolved-tool plan and therefore returns 'Left' with the
-- instruction — is unit-tested.
module HostBootstrap.Ensure.Homebrew (reconciler, installSteps) where

import HostBootstrap.Ensure
  ( InstallStep,
    Reconciler (..),
    installAndVerify,
    toolPresent,
  )
import HostBootstrap.HostTool (HostTool (Brew))
import HostBootstrap.Substrate (Substrate, isAppleSilicon)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "homebrew",
      reconcilerSummary = "Ensure Homebrew is installed (Apple silicon)",
      appliesTo = isAppleSilicon,
      requirement = "apple-silicon",
      reconcile = installAndVerify "homebrew" (\cfg -> pure (toolPresent cfg Brew)) installSteps
    }

-- | Homebrew has no resolved-tool install plan (it is the toolchain root). The
-- planner always returns 'Left' with the install instruction, so an absent
-- @brew@ fails fast rather than attempting an impossible auto-install.
installSteps :: Substrate -> Either String [InstallStep]
installSteps _ =
  Left "Homebrew is the host toolchain root; the Python bootstrapper installs it pre-binary. Install from https://brew.sh and retry."
