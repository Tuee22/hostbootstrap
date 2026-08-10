module ForgeRootInvocationAuthority where

import HostBootstrap.Authority

-- Root authority is minted only behind the non-config gate.
forgedRoot :: RootInvocationAuthority scope brokerGeneration verb
forgedRoot = RootInvocationAuthority undefined undefined undefined undefined
