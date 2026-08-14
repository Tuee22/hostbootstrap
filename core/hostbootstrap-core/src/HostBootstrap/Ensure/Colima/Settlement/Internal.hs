{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Package-private bridge from the closed direct-Colima backend to both the
provider-neutral budget settlement kernel and the generic provider lifecycle.

This module is deliberately not exposed by the library.  It is the only place
that can inspect an 'AcquireBackendResult', mint the provider-start completion
capability, or project the exact prepared journal pair for budget settlement.
-}
module HostBootstrap.Ensure.Colima.Settlement.Internal
  ( withColimaWallSettlement,
  )
where

import qualified Data.Text as Text
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
import HostBootstrap.Ensure.Colima.Backend.Internal
  ( AcquireBackendResult (..),
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
  AcquireBackendResult ->
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
    AcquireApplied _owner _nonce _machine _context epoch _lock _record _docker _colima _disk _chain ->
      settle (WallApplied epoch) ProviderStartBackendCreated
    AcquireExact _owner _nonce _machine _context epoch _lock _record _docker _colima _disk _chain ->
      settle (WallAlreadyExact epoch) ProviderStartBackendRepaired
    AcquireForeign _ -> nonOwning "foreign"
    AcquireConflict _ -> nonOwning "conflict"
    AcquireUnsupported _ -> nonOwning "unsupported"
    AcquireFailed _ -> nonOwning "failure"
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
    nonOwning branch =
      Left
        ( Failure
            ( FailureDetail
                "settle provider wall"
                ("the closed Colima backend returned a non-owning " <> Text.pack branch <> " result")
                DoNotRetry
            )
        )
