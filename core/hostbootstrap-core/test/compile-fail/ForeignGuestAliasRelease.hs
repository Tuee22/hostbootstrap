module ForeignGuestAliasRelease where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Alias

badRelease ::
  GuestAliasSpec ->
  ResourceHandle scope planId aliasId DurableAliasResource Unmanaged Observed ->
  OwnershipReceipt scope planId aliasId DurableAliasResource ->
  Either ReconcileError ()
badRelease spec handle receipt =
  withPreparedGuestAliasRelease spec handle receipt 1 (const ())
