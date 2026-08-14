{- | The acquisition package is not the independently journaled cleanup gate. -}
module ColimaAcquireCallAsCleanupGate where

import HostBootstrap.Ensure.Colima
  ( ColimaCleanupAuthority,
    PreparedColimaCleanupCall,
    PreparedColimaWallCall,
    prepareColimaCleanupCall,
  )
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.ProjectPlan
  ( PlannedResource,
    ProjectPlan,
    ProviderResource,
  )
import HostBootstrap.Reconcile (ReconcileError)

data Scope
data SpecificationDigest
data Plan
data ConfigurationIdentity
data Configuration scope
data ProviderResourceIdentity
data ProviderFrame
data Budget
data Capability
data Wall
data Workloads
data Partition
data Reservation
data Epoch
data Fence

prepareWithAcquisitionPackage ::
  PreparedGate ->
  ProjectPlan Scope SpecificationDigest Plan ConfigurationIdentity Configuration ->
  PlannedResource Scope Plan ProviderResourceIdentity ProviderResource ProviderFrame ->
  PreparedColimaWallCall
    Scope
    SpecificationDigest
    Plan
    ConfigurationIdentity
    ProviderResourceIdentity
    ProviderFrame
    Budget
    Capability
    Wall
    Workloads
    Partition
    Reservation
    Fence ->
  ColimaCleanupAuthority
    Scope
    SpecificationDigest
    Plan
    ConfigurationIdentity
    ProviderResourceIdentity
    ProviderFrame
    Wall
    Epoch
    Fence ->
  IO
    ( Either
        ReconcileError
        ( PreparedColimaCleanupCall
            Scope
            SpecificationDigest
            Plan
            ConfigurationIdentity
            ProviderResourceIdentity
            ProviderFrame
            Wall
            Epoch
            Fence
        )
    )
prepareWithAcquisitionPackage _teardownGate plan provider acquire authority =
  prepareColimaCleanupCall plan provider acquire authority
