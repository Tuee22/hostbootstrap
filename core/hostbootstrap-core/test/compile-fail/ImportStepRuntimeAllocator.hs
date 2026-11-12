module ImportStepRuntimeAllocator where

import HostBootstrap.Lifecycle.Execution (ResourceCarrier, StepRuntime, newStepRuntime)

retained :: ResourceCarrier scope planId -> IO (StepRuntime scope planId)
retained = newStepRuntime
