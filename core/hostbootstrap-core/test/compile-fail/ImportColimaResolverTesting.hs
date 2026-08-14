{- | Downstream code cannot import the private direct-Colima resolver test facade. -}
module ImportColimaResolverTesting where

import HostBootstrap.Ensure.Colima.Backend.Resolver.Testing

bad :: ()
bad = ()
