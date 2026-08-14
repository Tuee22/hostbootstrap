{- | Downstream code cannot import lifecycle-context constructors or the
root/nested authority eliminators. -}
module ImportLifecycleContextInternal where

import HostBootstrap.Lifecycle.Context.Internal

bad :: ()
bad = ()
