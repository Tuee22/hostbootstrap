{- | Downstream code cannot import the private direct-Colima command runner. -}
module ImportColimaBackendRunner where

import HostBootstrap.Ensure.Colima.Backend.Runner

bad :: ()
bad = ()
