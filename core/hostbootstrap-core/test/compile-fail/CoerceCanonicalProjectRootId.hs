module CoerceCanonicalProjectRootId where

import Data.Coerce (coerce)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)

data Scope
data RootA
data RootB

crossRoot :: CanonicalProjectRoot Scope RootA -> CanonicalProjectRoot Scope RootB
crossRoot = coerce
