{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Package-private bridge from the closed direct-Colima backend to both the
provider-neutral budget settlement kernel and the generic provider lifecycle.

This module is deliberately not exposed by the library.  It is the only place
that can inspect a native Colima settlement observation, mint the provider-start completion
capability, or project the exact prepared journal pair for budget settlement.
-}
module HostBootstrap.Ensure.Colima.Settlement.Internal
  ( ColimaWallSettlementObservation (..),
    withColimaWallSettlement,
  )
where

import Data.Word (Word64)
import HostBootstrap.Cluster.Budget
  ( ColimaProvider,
    PreparedProviderWallCall,
    ProviderWallAuthority,
    WallAcquireObservation (..),
    settleProviderWallCall,
    withLiveProviderWall,
  )
import HostBootstrap.Cluster.Budget.Internal
  ( withProviderWallSettlementPermitFromObservation,
  )
import HostBootstrap.Reconcile
  ( ChangeView,
    FailureDetail (..),
    Managed,
    OwnershipReceipt,
    PreparedProviderStart,
    ProviderResource,
    ReconcileError (..),
    RecoveryDisposition (DoNotRetry),
    ResourceHandle,
    Running,
    completePreparedProviderStart,
    withPreparedProviderStartParts,
    withReconcileResult,
  )
import HostBootstrap.Reconcile.ProviderStart.Internal
  ( ProviderStartBackendResult (..),
    ProviderStartProjectionAuthority (..),
  )

data ColimaWallSettlementObservation
  = ColimaWallSettlementApplied Word64
  | ColimaWallSettlementAlreadyExact Word64
  deriving (Eq, Show)

withColimaWallSettlement ::
  PreparedProviderWallCall
    scope
    planId
    budgetId
    ColimaProvider
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  PreparedProviderStart
    scope
    planId
    providerResourceId
    operationKey
    callDigest
    attempt
    journalVersion ->
  ColimaWallSettlementObservation ->
  ( forall wallEpoch.
    ProviderWallAuthority scope planId ColimaProvider wallSpecId wallEpoch fence ->
    ResourceHandle scope planId providerResourceId ProviderResource Managed Running ->
    OwnershipReceipt scope planId providerResourceId ProviderResource ->
    ChangeView ->
    ChangeView ->
    result
  ) ->
  Either ReconcileError result
withColimaWallSettlement prepared start backendResult consume =
  case backendResult of
    ColimaWallSettlementApplied epoch ->
      settle (WallApplied epoch) ProviderStartBackendCreated
    ColimaWallSettlementAlreadyExact epoch ->
      settle (WallAlreadyExact epoch) ProviderStartBackendRepaired
  where
    settle observation startResult =
      withPreparedProviderStartParts
        ProviderStartProjectionAuthority
        start
        ( \gate operation preconditions -> do
            permitted <-
              withProviderWallSettlementPermitFromObservation
                prepared
                gate
                operation
                preconditions
                observation
                ( \permit ->
                    settleProviderWallCall prepared permit $ \live ->
                      withLiveProviderWall
                        live
                        ( \authority wallChange ->
                            completePreparedProviderStart start startResult
                              >>= \reconciled ->
                                withReconcileResult
                                  reconciled
                                  ( \handle receipt providerChange ->
                                      Right (consume authority handle receipt wallChange providerChange)
                                  )
                                  ( \_ _ ->
                                      Left
                                        ( Failure
                                            ( FailureDetail
                                                "settle Colima provider start"
                                                "an owning Colima backend result settled as a foreign provider"
                                                DoNotRetry
                                            )
                                        )
                                  )
                        )
                        ( \_ _ _ ->
                            Left
                              ( Failure
                                  ( FailureDetail
                                      "settle Colima provider start"
                                      "the Colima provider key unexpectedly produced a WSL global-wall lease"
                                      DoNotRetry
                                  )
                              )
                        )
                )
            settledWall <- permitted
            settledWall
        )
