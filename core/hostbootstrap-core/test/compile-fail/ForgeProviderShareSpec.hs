module ForgeProviderShareSpec where

import HostBootstrap.Substrate.Provider.Reconcile

-- Share declarations must pass the public path validation boundary.
badSpec :: ProviderShareSpec
badSpec = ProviderShareSpec "/host/source" "/guest/target"
