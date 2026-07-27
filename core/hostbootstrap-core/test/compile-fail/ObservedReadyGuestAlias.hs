module ObservedReadyGuestAlias where

import HostBootstrap.Readiness
import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Alias

badPrepare ::
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
  ResourceHandle scope planId shareId DurableShareResource Managed sharePhase ->
  ObservedReady DurableShareReady ->
  GuestAliasSpec ->
  Either ReconcileError ()
badPrepare planned edge aliasHandle shareHandle observedReady spec =
  withPreparedGuestAliasCall
    planned
    edge
    aliasHandle
    shareHandle
    observedReady
    spec
    1
    1
    (const ())
