module CallerMintedBackendProbe where

import HostBootstrap.ProjectPlan (PlannedResource, ProviderResource)
import HostBootstrap.Readiness

-- If the injector is made public again, this complete public call would compile.
callerMinted :: PlannedResource scope planId resourceId ProviderResource frame -> ()
callerMinted planned =
    withBackendProbe
        ProviderRespondingProbe
        planned
        (\_ -> pure (ProbeReady (BackendReady 1 1 1 ())))
        (const ())
