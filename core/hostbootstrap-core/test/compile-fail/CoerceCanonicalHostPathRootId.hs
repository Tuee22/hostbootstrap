module CoerceCanonicalHostPathRootId where

import Data.Coerce (coerce)
import HostBootstrap.ProjectRoot (CanonicalHostPath)

data Scope
data RootA
data RootB

crossRoot :: CanonicalHostPath Scope RootA -> CanonicalHostPath Scope RootB
crossRoot = coerce
