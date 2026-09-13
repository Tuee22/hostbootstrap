module ObservedReadyGuestAlias where

import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.ProjectPlan (PlannedEdge, PlannedResource)
import HostBootstrap.Readiness
import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Alias
import HostBootstrap.Substrate.Provider.Reconcile

-- The alias call consumes the dependency probe that proved the share it depends
-- on is present, not a bare readiness observation. A readiness answer is what a
-- probe reports; it is not the probe, and substituting one skips the dependency
-- the call is ordered behind.
badPrepare ::
  StrongAliasBackend scope planId providerId backendId capabilityId ->
  ManagedProviderHandle scope planId backendId providerId Running ->
  ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned ->
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
badPrepare backend managed share planned edge aliasHandle observedReady spec gate =
  withPreparedGuestAliasCall
    backend
    managed
    share
    planned
    edge
    aliasHandle
    observedReady
    spec
    gate
    (const ())
