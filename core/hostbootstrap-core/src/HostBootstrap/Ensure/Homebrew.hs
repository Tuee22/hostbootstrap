{- | The @ensure homebrew@ reconciler: Homebrew present on Apple silicon.

Homebrew is the host toolchain root, so it cannot be installed through a
resolved host tool (there is no package manager to bootstrap it). The Python
bootstrapper asserts its presence as a host minimum (see
@development_plan_standards.md § N@); the operator installs it from brew.sh.
This reconciler is a verified no-op when @brew@ is present and fails fast with
the install instruction when it is absent. The pure 'installSteps' planner —
which has no resolved-tool plan and therefore returns 'Left' with the
instruction — is unit-tested.
-}
module HostBootstrap.Ensure.Homebrew (reconciler, installSteps) where

import HostBootstrap.Ensure (
    FramePlan (ProvidedElsewhere),
    InstallStep,
    Reconciler (..),
    appleRow,
    frameTable,
    installAndVerify,
    reconcilerInstallSteps,
    toolPresent,
 )
import HostBootstrap.HostTool (HostTool (Brew))
import HostBootstrap.Substrate (Substrate)

reconciler :: Reconciler
reconciler =
    Reconciler
        { reconcilerName = "homebrew"
        , reconcilerSummary = "Ensure Homebrew is installed (Apple silicon)"
        , -- One row, and it installs nothing: Homebrew is the toolchain root, so
          -- there is no resolved tool that could lay it down. The row still exists,
          -- because the dependency is genuinely probed here — an absent @brew@ must
          -- fail fast with the instruction rather than read as a wrong host.
          reconcilerFrames =
            frameTable
                [ appleRow
                    ( ProvidedElsewhere
                        "Homebrew is the host toolchain root; the Python bootstrapper asserts it as a host minimum. Install from https://brew.sh and retry."
                    )
                ]
        , reconcile = installAndVerify "homebrew" (\cfg -> pure (toolPresent cfg Brew)) installSteps
        }

installSteps :: Substrate -> Either String [InstallStep]
installSteps = reconcilerInstallSteps reconciler
