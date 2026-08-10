module ForeignGuestAliasRelease where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Alias

badRelease ::
  PreparedGuestAliasCall scope planId providerId backendId capabilityId aliasId shareId operationKey callDigest attempt journalVersion ->
  GuestAliasSpec ->
  ResourceHandle scope planId aliasId DurableAliasResource Unmanaged Observed ->
  OwnershipReceipt scope planId aliasId DurableAliasResource ->
  Either ReconcileError ()
badRelease prepared _spec handle receipt =
  withPreparedGuestAliasRelease prepared handle receipt 1 (const ())
