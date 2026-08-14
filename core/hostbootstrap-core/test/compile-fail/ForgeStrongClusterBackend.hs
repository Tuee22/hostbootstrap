{- | Production discovery exports the capability type abstractly; its private
validated constructor cannot be invoked by a downstream consumer.
-}
module ForgeStrongClusterBackend where

import HostBootstrap.Cluster.Backend (StrongClusterBackend)

badBackend = StrongClusterBackend
