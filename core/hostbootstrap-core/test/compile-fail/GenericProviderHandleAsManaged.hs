module GenericProviderHandleAsManaged where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Reconcile

-- Generic reconciliation ownership is not provider/backend authority.
badStartable ::
  ResourceHandle scope planId providerId ProviderResource Managed Provisioned ->
  ProviderStartable scope planId backendId providerId Provisioned
badStartable = providerStartableAfterProvision
