module ForgeIncusProviderCapability where

import HostBootstrap.Ensure.Incus (
    IncusProviderCapability (IncusProviderCapability),
 )

forged :: IncusProviderCapability ()
forged = IncusProviderCapability
