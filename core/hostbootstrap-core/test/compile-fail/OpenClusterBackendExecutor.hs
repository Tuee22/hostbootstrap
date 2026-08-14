{- | The public cluster backend exposes only the opaque production capability,
never the raw executor/result constructors used by package-internal tests.
-}
module OpenClusterBackendExecutor where

import HostBootstrap.Cluster.Backend
    ( ClusterCommandResult (..)
    , ClusterExec (..)
    )

badExecutor = ClusterExec

badResult = ClusterCommandResult
