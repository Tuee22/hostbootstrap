{- | A chart call package is produced only by exact declaration, activation,
dependency, and journal preparation; its constructor is not public. -}
module ForgePreparedChartWorkload where

import HostBootstrap.Cluster.Backend (PreparedChartWorkload)

forged ::
    PreparedChartWorkload
        scope
        planId
        chartId
        chartFrame
        clusterId
        clusterPhase
        operationKey
        callDigest
        attempt
        journalVersion
forged = PreparedChartWorkload
