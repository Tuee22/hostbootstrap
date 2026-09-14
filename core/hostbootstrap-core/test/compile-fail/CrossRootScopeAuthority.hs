module CrossRootScopeAuthority where

import Data.Coerce (coerce)
import HostBootstrap.Authority

data ScopeA
data ScopeB

wrongScope ::
    RootScopeAuthority ScopeA ->
    RootScopeAuthority ScopeB
wrongScope = coerce
