module BootNonProviderResource where

import HostBootstrap.Reconcile

-- The provider-only provisioned-to-running shortcut must not bypass the
-- staged/built lifecycle of another resource kind.
badBoot ::
  ResourceHandle scope planId shareId DurableShareResource Managed Provisioned ->
  Either
    ReconcileError
    ( PhaseTransition
        scope
        planId
        shareId
        DurableShareResource
        Provisioned
        Running
    )
badBoot = planProviderBoot
