{- | Downstream code cannot import the package-private provider-start
completion capabilities. -}
module ImportProviderStartInternal where

import HostBootstrap.Reconcile.ProviderStart.Internal

bad :: ()
bad = ()
