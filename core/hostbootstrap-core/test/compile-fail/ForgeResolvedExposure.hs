module ForgeResolvedExposure where

import HostBootstrap.Cluster.Backend (ResolvedExposure (ResolvedExposure))

forged = ResolvedExposure "web" 30080 "cluster" 30080 "relay" 1 "operation"
