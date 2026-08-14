{- | A reservation minted for one constructive partition cannot prepare a
provider-wall call for another partition from the same plan.
-}
module CrossPartitionProviderWallReservation where

import HostBootstrap.Cluster.Budget
  ( BudgetError,
    BudgetPartition,
    PreparedProviderWallCall,
    ProviderWallReservation,
    ProviderWallSpec,
    prepareProviderWallCall,
  )

crossPartition ::
  ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId ->
  BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionA ->
  BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionB ->
  ProviderWallReservation
    scope
    planId
    budgetId
    provider
    capabilityId
    wallSpecId
    workloadSetId
    partitionA
    reservationId
    fence ->
  Either
    BudgetError
    ( PreparedProviderWallCall
        scope
        planId
        budgetId
        provider
        capabilityId
        wallSpecId
        workloadSetId
        partitionB
        reservationId
        fence
    )
crossPartition wall _partitionA partitionB reservation =
  prepareProviderWallCall "project" wall partitionB reservation
