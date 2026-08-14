{- | A provider transition that has not reached Running cannot mint the opaque
dependency package consumed by cluster preparation.
-}
module ProvisionedProviderClusterDependency where

import HostBootstrap.Reconcile (Provisioned, ReconcileError)
import HostBootstrap.Substrate.Provider.Backend
import HostBootstrap.Substrate.Provider.Reconcile (ProviderPhaseAdvance)

provisionedDependency ::
  StrongProviderBackend backendId ->
  ProviderPhaseAdvance scope planId backendId providerId Provisioned ->
  Either ReconcileError (RunningProviderDependency scope planId providerId)
provisionedDependency backend advance =
  withRunningProviderDependency backend advance id
