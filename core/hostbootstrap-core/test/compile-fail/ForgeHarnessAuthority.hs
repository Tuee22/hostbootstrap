module ForgeHarnessAuthority where

import HostBootstrap.Config.Vocab (
    HarnessConfigAuthority (HarnessConfigAuthority),
 )

data Project
data Run

forged :: HarnessConfigAuthority Project Run
forged = HarnessConfigAuthority "forged"
