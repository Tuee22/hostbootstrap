module ForgeProviderPhaseAdvance where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Reconcile

-- Only settlement of the exact prepared transition can mint its opaque
-- backend-indexed successor wrapper.
badAdvance ::
  ProviderPhaseAdvance scope planId backendId providerId Running
badAdvance = ProviderPhaseAdvance
