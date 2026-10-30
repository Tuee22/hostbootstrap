module HandoffLifecycleProducers where

import HostBootstrap.Handoff (
    withAcknowledgedBoundReverseLifecycleCompletionKernel,
    withAcknowledgedForwardLifecycleCompletionKernel,
    withRehydratedAcknowledgedReverseLifecycleCompletionKernel,
 )

hiddenLifecycleProducers :: ()
hiddenLifecycleProducers = ()
