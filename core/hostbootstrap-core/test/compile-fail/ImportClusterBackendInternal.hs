{- | The injected executor and backend constructor live in a Cabal-private
component; a downstream consumer cannot import the testing escape hatch.
-}
module ImportClusterBackendInternal where

import HostBootstrap.Cluster.Backend.Internal

badBackend = ClusterExec
