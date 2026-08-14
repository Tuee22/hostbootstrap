{- | The public type is opaque; its authority constructor is not exported. -}
module ForgeProviderWallSettlementPermit where

import HostBootstrap.Cluster.Budget (ProviderWallSettlementPermit)

forged ::
  ProviderWallSettlementPermit
    scope
    planId
    providerResourceId
    budgetId
    provider
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence
    operationKey
    callDigest
    attempt
    journalVersion
forged = ProviderWallSettlementPermit
