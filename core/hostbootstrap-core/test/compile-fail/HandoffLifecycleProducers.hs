module HandoffLifecycleProducers where

import HostBootstrap.Handoff
    ( withAcknowledgedBoundReverseLifecycleCompletionKernel
    , withAcknowledgedForwardLifecycleCompletionKernel
    , withForwardLifecycleReportKernel
    , withRehydratedAcknowledgedReverseLifecycleCompletionKernel
    , withReverseLifecycleReportKernel
    )

hiddenLifecycleProducers :: ()
hiddenLifecycleProducers = ()
