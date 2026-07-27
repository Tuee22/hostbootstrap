module CrossAliasReceipt where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Alias

badRelease ::
  GuestAliasSpec ->
  ResourceHandle scope planId aliasA DurableAliasResource Managed phase ->
  OwnershipReceipt scope planId aliasB DurableAliasResource ->
  Either ReconcileError ()
badRelease spec handle receipt =
  withPreparedGuestAliasRelease spec handle receipt 1 (const ())
