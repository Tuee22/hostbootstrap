module ConstructProviderProbeRequest where

import HostBootstrap.Substrate.Provider

-- A descriptive request view cannot mint a provider-owned request.
forgedRequest :: ProviderProbeRequest
forgedRequest = ProviderProbeRequest (ProviderGuestProbeRequest ["true"])
