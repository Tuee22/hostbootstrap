module CoerceCanonicalHostPathScope where

import Data.Coerce (coerce)
import HostBootstrap.ProjectRoot (CanonicalHostPath)

data ScopeA
data ScopeB
data Root

crossScope :: CanonicalHostPath ScopeA Root -> CanonicalHostPath ScopeB Root
crossScope = coerce
