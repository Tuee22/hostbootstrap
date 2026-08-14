{- | Downstream code cannot import the package-private Colima settlement bridge. -}
module ImportColimaSettlementInternal where

import HostBootstrap.Ensure.Colima.Settlement.Internal

bad :: ()
bad = ()
