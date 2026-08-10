module ForgeProviderObservation where

import HostBootstrap.Substrate.Provider.Reconcile

-- Raw provider reports are package-private parser output, not caller input.
badProvision = ProviderProvisionCreated 1

badReady = ProviderReadyObserved 1
