module CrossBackendAliasCall where

import HostBootstrap.Substrate.Provider.Alias

crossBackendCall ::
  StrongAliasBackend scope planId providerId backendA capabilityId ->
  PreparedGuestAliasCall scope planId providerId backendB capabilityId aliasId shareId operationKey callDigest attempt journalVersion ->
  IO (AliasCallResult scope planId providerId backendB capabilityId aliasId shareId operationKey callDigest attempt journalVersion)
crossBackendCall = runPreparedGuestAliasCall
