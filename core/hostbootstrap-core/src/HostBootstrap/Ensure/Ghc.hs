-- | The @ensure ghc@ reconciler: the host GHC toolchain for native Apple builds.
--
-- Install-and-verify (see @development_plan_standards.md § L@): @brew install
-- ghcup@ then @ghcup install ghc@ if GHC is absent, a verified no-op when the
-- host GHC is present. The pure 'installSteps' planner is unit-tested.
module HostBootstrap.Ensure.Ghc (reconciler, installSteps) where

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
import HostBootstrap.HostTool (HostTool (Brew, Ghc, Ghcup))
import HostBootstrap.Substrate (Substrate)

reconciler :: Reconciler
reconciler =
  Reconciler
    { reconcilerName = "ghc",
      reconcilerSummary = "Ensure the host GHC toolchain (Apple silicon native build)",
      -- One row. @brew install ghcup@ then @ghcup install ghc@; the tools are
      -- re-resolved after each step, so @ghcup@ is discoverable for the second
      -- step once @brew@ has laid it down.
      reconcilerFrames =
        frameTable
          [ appleRow
              ( InstallHere
                  [ InstallStep Brew ["install", "ghcup"],
                    InstallStep Ghcup ["install", "ghc"]
                  ]
              )
          ],
      reconcile = installAndVerify "ghc" (\cfg -> pure (toolPresent cfg Ghc)) installSteps
    }

installSteps :: Substrate -> Either String [InstallStep]
installSteps = reconcilerInstallSteps reconciler
