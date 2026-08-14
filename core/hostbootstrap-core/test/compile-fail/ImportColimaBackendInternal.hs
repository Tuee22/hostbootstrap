{- | Downstream code cannot import the private direct-Colima backend component. -}
module ImportColimaBackendInternal where

import HostBootstrap.Ensure.Colima.Backend.Internal

bad :: ()
bad = ()
