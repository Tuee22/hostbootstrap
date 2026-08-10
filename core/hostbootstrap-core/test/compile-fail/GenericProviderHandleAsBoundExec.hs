module GenericProviderHandleAsBoundExec where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Backend

-- Provider-bound guest execution requires the exact backend-indexed wrapper,
-- not a generic managed provider handle.
badBoundExec ::
  StrongProviderBackend backendId ->
  ResourceHandle scope planId providerId ProviderResource Managed Running ->
  Either ReconcileError ()
badBoundExec backend handle = withProviderBoundExec backend handle (const ())
