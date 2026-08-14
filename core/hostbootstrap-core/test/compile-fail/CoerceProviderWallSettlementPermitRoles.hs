{- | Every plan, resource, reservation, and prepared-operation axis on a wall
settlement permit is nominal.
-}
module CoerceProviderWallSettlementPermitRoles where

import Data.Coerce (coerce)
import HostBootstrap.Cluster.Budget (ProviderWallSettlementPermit)

data Scope
data PlanA
data PlanB
data ProviderResource
data Budget
data Provider
data Capability
data Wall
data Workloads
data Partition
data Reservation
data Fence
data OperationA
data OperationB
data CallDigest
data Attempt
data JournalVersion

wrongPlan ::
  ProviderWallSettlementPermit Scope PlanA ProviderResource Budget Provider Capability Wall Workloads Partition Reservation Fence OperationA CallDigest Attempt JournalVersion ->
  ProviderWallSettlementPermit Scope PlanB ProviderResource Budget Provider Capability Wall Workloads Partition Reservation Fence OperationA CallDigest Attempt JournalVersion
wrongPlan = coerce

wrongOperation ::
  ProviderWallSettlementPermit Scope PlanA ProviderResource Budget Provider Capability Wall Workloads Partition Reservation Fence OperationA CallDigest Attempt JournalVersion ->
  ProviderWallSettlementPermit Scope PlanA ProviderResource Budget Provider Capability Wall Workloads Partition Reservation Fence OperationB CallDigest Attempt JournalVersion
wrongOperation = coerce
