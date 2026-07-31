module ForgeCommandAuthority where

import HostBootstrap.Authority

-- Command authority is minted only by the effectful gate that reserves its
-- one-use invocation; there is no constructor to call.
forgedCommand :: CommandAuthority scope planId frame brokerGeneration verb phase
forgedCommand = CommandAuthority (InvocationId "forged") "host" (BrokerEpoch 1) ProjectUp Execute

-- Root authority is likewise minted only behind the non-config gate.
forgedRoot :: RootInvocationAuthority scope brokerGeneration verb
forgedRoot = RootInvocationAuthority "project" (BrokerEpoch 1) ProjectUp
