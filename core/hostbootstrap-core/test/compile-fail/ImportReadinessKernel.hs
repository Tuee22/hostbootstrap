module ImportReadinessKernel where

import HostBootstrap.ProjectPlan (PlannedResource, ProviderResource)
import HostBootstrap.Readiness (
    BackendProbeKey (ProviderRespondingProbe),
    BackendReady (BackendReady),
    ProbeResult (ProbeReady),
 )
import HostBootstrap.Readiness.Kernel (withBackendProbe)

-- The injection boundary belongs to a private Cabal unit.
blocked :: PlannedResource scope planId resourceId ProviderResource frame -> ()
blocked planned =
    withBackendProbe
        ProviderRespondingProbe
        planned
        (\_ -> pure (ProbeReady (BackendReady 1 1 1 ())))
        (const ())
