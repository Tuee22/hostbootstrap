module ImportTeardownExecutorInternal where

-- Reverse child projection and execution remain package-private; downstream
-- code cannot turn descriptive recovery bytes into executable teardown work.
import HostBootstrap.Teardown.Executor.Internal
    ( runStorelessReversePreparedKernel
    , withStorelessReverseDescentResultKernel
    , withStorelessReverseExecutorKernel
    )
