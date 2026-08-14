{- | Downstream code cannot import the package-private settlement producer. -}
module ImportBudgetInternal where

import HostBootstrap.Cluster.Budget.Internal

bad :: ()
bad = ()
