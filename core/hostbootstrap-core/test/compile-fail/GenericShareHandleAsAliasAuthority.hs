module GenericShareHandleAsAliasAuthority where

import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.ProjectPlan (PlannedEdge, PlannedResource)
import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Alias
import HostBootstrap.Substrate.Provider.Reconcile

-- Alias preparation accepts only the provider-derived share wrapper retaining
-- the same provider/backend origin, never a generic managed share handle.
badAlias ::
  StrongAliasBackend scope planId providerId backendId capabilityId ->
  ManagedProviderHandle scope planId backendId providerId Running ->
  ResourceHandle scope planId shareId DurableShareResource Managed Provisioned ->
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
  DependencyProbe scope planId shareId DurableShareResource ->
  GuestAliasSpec ->
  PreparedGate ->
  IO (Either ReconcileError ())
badAlias backend provider genericShare planned edge observed probe spec gate =
  withPreparedGuestAliasCall
    backend
    provider
    genericShare
    planned
    edge
    observed
    probe
    spec
    gate
    (const ())
