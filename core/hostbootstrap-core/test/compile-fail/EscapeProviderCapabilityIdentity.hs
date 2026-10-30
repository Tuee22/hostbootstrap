module EscapeProviderCapabilityIdentity where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider
import HostBootstrap.Substrate.Provider.Reconcile (ManagedProviderHandle)

data ChosenCapability

-- A caller cannot choose or retain the discovery transition's fresh identity.
escapeCapability ::
    ManagedProviderHandle scope planId backendId providerId Running ->
    SubstrateProvider ->
    IO (Either ProviderError (ProviderCapability scope planId providerId backendId ChosenCapability))
escapeCapability managed provider =
    discoverProvider managed provider undefined pure
