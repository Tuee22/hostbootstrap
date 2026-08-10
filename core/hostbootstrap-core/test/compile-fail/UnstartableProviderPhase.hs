module UnstartableProviderPhase where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Reconcile

-- A running provider cannot be relabelled as a fresh provisioned allocation.
badStartable ::
  ManagedProviderHandle scope planId backendId providerId Running ->
  ProviderStartable scope planId backendId providerId Running
badStartable = providerStartableAfterProvision
