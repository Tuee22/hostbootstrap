{- | The @ensure ghc@ reconciler: the host GHC toolchain for native Apple builds.

Install-and-verify (see @development_plan_standards.md § L@): @brew install
ghcup@ then @ghcup install ghc --set recommended@ if GHC is absent, a verified
no-op when the host GHC is present. The pure 'installSteps' planner is unit-tested.
-}
module HostBootstrap.Ensure.Ghc (reconciler, installSteps) where

import HostBootstrap.Ensure (
    FramePlan (InstallHere),
    InstallStep (..),
    Reconciler (..),
    appleRow,
    frameTable,
    installAndVerify,
    reconcilerInstallSteps,
    toolPresent,
 )
import HostBootstrap.HostTool (HostTool (Brew, Ghc, Ghcup))
import HostBootstrap.Substrate (Substrate)

reconciler :: Reconciler
reconciler =
    Reconciler
        { reconcilerName = "ghc"
        , reconcilerSummary = "Ensure the host GHC toolchain (Apple silicon native build)"
        , -- Install the recommended GHC and set it as default. Tools are
          -- re-resolved after each step, including ghcup's install directory,
          -- so the next step and final probe find the newly installed tools.
          reconcilerFrames =
            frameTable
                [ appleRow
                    ( InstallHere
                        [ InstallStep Brew ["install", "ghcup"]
                        , InstallStep Ghcup ["install", "ghc", "--set", "recommended"]
                        ]
                    )
                ]
        , reconcile = installAndVerify "ghc" (\cfg -> pure (toolPresent cfg Ghc)) installSteps
        }

installSteps :: Substrate -> Either String [InstallStep]
installSteps = reconcilerInstallSteps reconciler
