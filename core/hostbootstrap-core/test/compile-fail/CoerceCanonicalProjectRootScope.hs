module CoerceCanonicalProjectRootScope where

import Data.Coerce (coerce)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)

data ScopeA
data ScopeB
data Root

crossScope :: CanonicalProjectRoot ScopeA Root -> CanonicalProjectRoot ScopeB Root
crossScope = coerce
