module ForgeCommandAuthority where

import HostBootstrap.Authority

-- Command authority is minted only by the effectful gate that reserves its
-- one-use invocation; there is no constructor to call.
forgedCommand :: CommandAuthority scope planId frame brokerGeneration verb phase
forgedCommand = CommandAuthority undefined undefined undefined undefined undefined
