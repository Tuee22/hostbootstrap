module ForgeIncusProviderReady where

import HostBootstrap.Ensure.Incus (
    IncusProviderStatus (IncusProviderReady),
 )

forged :: IncusProviderStatus
forged = IncusProviderReady
