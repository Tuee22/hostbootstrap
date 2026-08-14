-- The raw backend observation/result constructors are package-private.
module ImportClusterObservationInternal where

import HostBootstrap.Cluster.Observation.Internal

badObservation = ClusterCreated "forged-container-id"
