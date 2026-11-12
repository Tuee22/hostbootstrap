module ImportLifecycleRuntimeCore where

import HostBootstrap.Lifecycle.Execution.Core (ResourceCarrierCore, StepRuntimeCore, newStepRuntimeCore)

retained :: ResourceCarrierCore scope planId dependencyPayload -> IO (StepRuntimeCore scope planId gate dependencyPayload)
retained = newStepRuntimeCore
