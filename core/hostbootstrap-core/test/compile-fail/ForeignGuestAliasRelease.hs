module ForeignGuestAliasRelease where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Alias

-- Releasing a guest alias consumes the managed handle the settlement minted,
-- which is what carries the ownership receipt this run established. A raw
-- observation of someone else's alias is not that handle, so a foreign alias
-- cannot be released through this route.
badRelease ::
    ResourceHandle scope planId aliasId DurableAliasResource Unmanaged Observed ->
    Either ReconcileError ()
badRelease handle = withPreparedGuestAliasRelease handle 1 (const ())
