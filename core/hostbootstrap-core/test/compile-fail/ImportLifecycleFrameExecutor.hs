module ImportLifecycleFrameExecutor where

-- The storeless frame executor is Cabal-private, so no consumer can name the
-- type, open one from bytes it chose, build a request, advance a coordinate,
-- or reach the local gate its execution mints.
import HostBootstrap.Lifecycle.FrameExecutor
    ( FrameExecutor
    , withAdvancedFrameExecutorKernel
    , withExecutedFrameNodeKernel
    , withFrameExecutorRequestKernel
    , withOpenedFrameExecutorKernel
    )
