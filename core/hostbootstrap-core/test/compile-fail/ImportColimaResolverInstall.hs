{- | Downstream code cannot import the private direct-Colima install kernel. -}
module ImportColimaResolverInstall where

import HostBootstrap.Ensure.Colima.Backend.Resolver.Install

bad :: ()
bad = ()
