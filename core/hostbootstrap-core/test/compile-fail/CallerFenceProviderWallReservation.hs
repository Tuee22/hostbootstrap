{- | A descriptive wall, partition, and caller-chosen number no longer mint a
provider reservation.  The exact project/provider operation and its durable
prepare gate are required.
-}
module CallerFenceProviderWallReservation where

import HostBootstrap.Cluster.Budget

oldReservation ::
  ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId ->
  BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
  Either BudgetError ()
oldReservation wall partition =
  withProviderWallReservation wall partition 1 (const ())
