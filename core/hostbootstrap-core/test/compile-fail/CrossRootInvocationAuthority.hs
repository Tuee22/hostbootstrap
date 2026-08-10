module CrossRootInvocationAuthority where

import Data.Coerce (coerce)
import HostBootstrap.Authority

data ScopeA
data ScopeB
data Generation

wrongRoot ::
    RootInvocationAuthority ScopeA Generation VerbUp ->
    RootInvocationAuthority ScopeB Generation VerbUp
wrongRoot = coerce
