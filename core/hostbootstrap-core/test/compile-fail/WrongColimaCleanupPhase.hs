{- | A successful Colima cleanup advances the provider to Destroyed only. -}
module WrongColimaCleanupPhase where

import HostBootstrap.Ensure.Colima
  ( PreparedColimaCleanupCall,
    runColimaCleanup,
  )
import HostBootstrap.ProjectPlan (ProviderResource)
import HostBootstrap.Reconcile
  ( PhaseAdvance,
    ReconcileError,
    Running,
  )

data Scope
data SpecificationDigest
data Plan
data Configuration
data ProviderResourceIdentity
data ProviderFrame
data Wall
data Epoch
data Fence

runAsStillRunning ::
  PreparedColimaCleanupCall
    Scope
    SpecificationDigest
    Plan
    Configuration
    ProviderResourceIdentity
    ProviderFrame
    Wall
    Epoch
    Fence ->
  IO
    ( Either
        ReconcileError
        (PhaseAdvance Scope Plan ProviderResourceIdentity ProviderResource Running)
    )
runAsStillRunning call = runColimaCleanup call
