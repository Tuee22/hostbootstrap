{- | Direct-Colima evidence and authorities can only be produced by the exact
prepare, locked backend, settlement, and cleanup-elimination path.
-}
module ForgeColimaAuthorities where

import HostBootstrap.Ensure.Colima
  ( ColimaCleanupAuthority,
    ColimaWallObservation,
    LiveColimaWall,
    PreparedColimaCleanupCall,
    PreparedColimaWallCall,
  )

data Scope
data SpecificationDigest
data Plan
data Configuration
data ProviderResource
data ProviderFrame
data Budget
data Capability
data Wall
data Workloads
data Partition
data Reservation
data Epoch
data Fence

forgePrepared ::
  PreparedColimaWallCall
    Scope
    SpecificationDigest
    Plan
    Configuration
    ProviderResource
    ProviderFrame
    Budget
    Capability
    Wall
    Workloads
    Partition
    Reservation
    Fence
forgePrepared = PreparedColimaWallCall

forgeLive ::
  LiveColimaWall
    Scope
    SpecificationDigest
    Plan
    Configuration
    ProviderResource
    ProviderFrame
    Wall
    Epoch
    Fence
forgeLive = LiveColimaWall

forgeCleanup ::
  ColimaCleanupAuthority
    Scope
    SpecificationDigest
    Plan
    Configuration
    ProviderResource
    ProviderFrame
    Wall
    Epoch
    Fence
forgeCleanup = ColimaCleanupAuthority

forgePreparedCleanup ::
  PreparedColimaCleanupCall
    Scope
    SpecificationDigest
    Plan
    Configuration
    ProviderResource
    ProviderFrame
    Wall
    Epoch
    Fence
forgePreparedCleanup = PreparedColimaCleanupCall

forgeOwnedObservation :: ColimaWallObservation
forgeOwnedObservation = ColimaOwnedWallObservation
