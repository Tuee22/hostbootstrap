module ForgeProviderBackendBinding where

import HostBootstrap.Substrate.Provider.Reconcile

-- Only successful backend discovery may mint a backend identity/fingerprint.
badBinding :: ProviderBackendBinding backendId
badBinding = ProviderBackendBinding "semantic" "realization"
