module CrossAliasCallResult where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Alias

crossAliasResult ::
  PreparedGuestAliasCall scope planId providerId backendId capabilityId aliasA shareId operationKey callDigest attempt journalVersion ->
  AliasCallResult scope planId providerId backendId capabilityId aliasB shareId operationKey callDigest attempt journalVersion ->
  Either ReconcileError (ReconcileResult scope planId aliasA DurableAliasResource Provisioned)
crossAliasResult prepared result =
  settlePreparedGuestAliasCall Nothing prepared result
