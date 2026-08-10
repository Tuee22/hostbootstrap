module ForgeRootScopeAuthority where

import HostBootstrap.Authority
import HostBootstrap.ProjectScope

data Project

forged :: RootScopeAuthority (Production Project)
forged = RootScopeAuthority "forged"
