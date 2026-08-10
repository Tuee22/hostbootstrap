module CrossAliasReceipt where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Alias

badRelease ::
  PreparedGuestAliasCall scope planId providerId backendId capabilityId aliasA shareId operationKey callDigest attempt journalVersion ->
  GuestAliasSpec ->
  ResourceHandle scope planId aliasA DurableAliasResource Managed phase ->
  OwnershipReceipt scope planId aliasB DurableAliasResource ->
  Either ReconcileError ()
badRelease prepared _spec handle receipt =
  withPreparedGuestAliasRelease prepared handle receipt 1 (const ())
