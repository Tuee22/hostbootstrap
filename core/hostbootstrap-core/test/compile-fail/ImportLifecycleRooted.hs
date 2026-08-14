module ImportLifecycleRooted where

import HostBootstrap.Lifecycle.Rooted
    ( RootedFrameSession
    , withAttachedRootedFrameSessionKernel
    , withRootOpenedFrameSessionKernel
    , withRootedFrameSessionKernel
    )

hidden ::
    RootedFrameSession scope rootPlanId broker catalogId frame sessionId verb -> ()
hidden _ = ()
