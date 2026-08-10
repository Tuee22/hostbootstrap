module CrossRootScopeAuthority where

import HostBootstrap.Authority
import Data.Coerce (coerce)

data ScopeA
data ScopeB

wrongScope ::
    RootScopeAuthority ScopeA ->
    RootScopeAuthority ScopeB
wrongScope = coerce
