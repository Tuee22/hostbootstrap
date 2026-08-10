module ObservedReadyGuestAlias where

import HostBootstrap.Readiness
import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Alias
import HostBootstrap.Lifecycle.Prepared (PreparedGate)

badPrepare ::
  StrongAliasBackend scope planId providerId backendId capabilityId ->
  ResourceHandle scope planId providerId ProviderResource Managed Running ->
  PlannedResource scope planId aliasId DurableAliasResource aliasFrame ->
  PlannedEdge
    scope
    planId
    aliasId
    DurableAliasResource
    aliasFrame
    shareId
    DurableShareResource
    shareFrame ->
  ResourceHandle scope planId aliasId DurableAliasResource Unclassified Observed ->
  ObservedReady DurableShareReady ->
  GuestAliasSpec ->
  PreparedGate ->
  IO (Either ReconcileError ())
badPrepare backend managed planned edge aliasHandle observedReady spec gate =
  withPreparedGuestAliasCall
    backend
    managed
    planned
    edge
    aliasHandle
    observedReady
    spec
    gate
    (const ())
