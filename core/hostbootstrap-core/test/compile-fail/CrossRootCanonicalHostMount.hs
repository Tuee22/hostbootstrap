module CrossRootCanonicalHostMount where

import HostBootstrap.Config.Vocab (Mount)
import HostBootstrap.Lift.Context (canonicalHostMount)
import HostBootstrap.ProjectRoot (CanonicalHostPath, CanonicalProjectRoot)

data Scope
data RootA
data RootB

badMount ::
    CanonicalProjectRoot Scope RootA ->
    CanonicalHostPath Scope RootB ->
    Mount
badMount root foreignPath =
    canonicalHostMount root foreignPath "/workspace/project/.data" False
