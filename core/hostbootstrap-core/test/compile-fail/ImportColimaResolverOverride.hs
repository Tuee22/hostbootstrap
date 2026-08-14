{- | Downstream code cannot import the private direct-Colima resolver override. -}
module ImportColimaResolverOverride where

import HostBootstrap.Ensure.Colima.Backend.Resolver.Override

bad :: ()
bad = ()
