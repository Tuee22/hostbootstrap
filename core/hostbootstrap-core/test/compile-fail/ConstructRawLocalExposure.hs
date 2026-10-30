module ConstructRawLocalExposure where

-- A local exposure must retain the runtime-owned endpoint and relay identity.

import HostBootstrap.Network (
    Exposure (ResolvedLocalExposure),
 )
