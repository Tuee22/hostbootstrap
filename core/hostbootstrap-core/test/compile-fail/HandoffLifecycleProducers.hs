module HandoffLifecycleProducers where

import HostBootstrap.Handoff (
    withAcknowledgedBoundReverseLifecycleCompletionKernel,
    withAcknowledgedForwardLifecycleCompletionKernel,
 )

hiddenLifecycleProducers :: ()
hiddenLifecycleProducers = ()
