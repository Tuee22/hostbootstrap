module PrepareCallerSelectedHostPort where

import HostBootstrap.Cluster.Backend (mkLoopbackExposure)

chosenByCaller = mkLoopbackExposure 30080 30080
