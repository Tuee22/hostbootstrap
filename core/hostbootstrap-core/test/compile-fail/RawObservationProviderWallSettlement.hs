{- | A caller-shaped observation cannot enter public settlement. -}
module RawObservationProviderWallSettlement where

import HostBootstrap.Cluster.Budget
import HostBootstrap.Reconcile (ReconcileError)

oldSettlement ::
  PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  WallAcquireObservation ->
  Either ReconcileError ()
oldSettlement prepared observation =
  settleProviderWallCall prepared observation (const ())
