module EscapeProviderCapabilityIdentity where

import HostBootstrap.Substrate.Provider
import HostBootstrap.Reconcile

data ChosenCapability

-- A caller cannot choose or retain the discovery transition's fresh identity.
escapeCapability ::
    ResourceHandle scope planId providerId ProviderResource Managed Running ->
    SubstrateProvider ->
    IO (Either ProviderError (ProviderCapability scope planId providerId backendId ChosenCapability))
escapeCapability managed provider =
    discoverProvider managed provider undefined pure
