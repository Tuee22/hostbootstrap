module ImportClusterOwnership where

import HostBootstrap.Cluster.Ownership (releaseOwnedCluster)

bypass = releaseOwnedCluster
