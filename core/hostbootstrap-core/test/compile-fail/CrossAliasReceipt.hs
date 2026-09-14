module CrossAliasReceipt where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Alias

-- A settlement names the alias it settled, and the managed handle it carries is
-- indexed by that alias. Consuming one with a continuation written for another
-- alias would move a receipt between objects.
badConsume ::
    GuestAliasCallSettlement scope planId providerId backendId capabilityId aliasA shareId ->
    ( ManagedGuestAliasHandle
        scope
        planId
        providerId
        backendId
        capabilityId
        aliasB
        shareId
        Provisioned ->
      ChangeView ->
      ()
    ) ->
    ()
badConsume settlement consume =
    withGuestAliasCallSettlement settlement consume (\_ _ _ _ -> ())
