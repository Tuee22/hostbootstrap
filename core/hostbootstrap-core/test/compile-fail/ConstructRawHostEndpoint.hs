module ConstructRawHostEndpoint where

-- A generic endpoint opener cannot bypass runtime-owned local exposure.

import HostBootstrap.Network (
    mkEndpoint,
 )
