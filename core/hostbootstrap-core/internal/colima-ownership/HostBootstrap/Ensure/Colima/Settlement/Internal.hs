-- | Private pure producer of provider-start capabilities and wall facts from a closed native result.
module HostBootstrap.Ensure.Colima.Settlement.Internal (
    ColimaWallSettlementObservation (..),
    withColimaWallSettlement,
)
where

import HostBootstrap.Cluster.Budget.Observation (WallAcquireObservation (..))
import HostBootstrap.Ensure.Colima.Observation (ColimaWallSettlementObservation (..))
import HostBootstrap.Reconcile.ProviderStart.Internal (
    ProviderStartBackendResult (..),
    ProviderStartProjectionAuthority (..),
 )

withColimaWallSettlement ::
    ColimaWallSettlementObservation ->
    (ProviderStartProjectionAuthority -> WallAcquireObservation -> ProviderStartBackendResult -> result) ->
    result
withColimaWallSettlement backendResult consume =
    case backendResult of
        ColimaWallSettlementApplied epoch ->
            consume ProviderStartProjectionAuthority (WallApplied epoch) ProviderStartBackendCreated
        ColimaWallSettlementAlreadyExact epoch ->
            consume ProviderStartProjectionAuthority (WallAlreadyExact epoch) ProviderStartBackendRepaired
