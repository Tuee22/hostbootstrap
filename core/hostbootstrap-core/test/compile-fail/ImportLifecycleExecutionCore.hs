module ImportLifecycleExecutionCore where

import HostBootstrap.Lifecycle.Execution.Core (ResourceCarrierCore, newResourceCarrierCore)

retained :: IO (ResourceCarrierCore scope planId dependencyPayload)
retained = newResourceCarrierCore
