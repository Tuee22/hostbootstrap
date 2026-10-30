module OpenClusterBackendExecutor where

-- The public backend cannot manufacture its opaque capability from raw driver inputs.

import HostBootstrap.Cluster.Backend (
    mkStrongClusterBackend,
 )
