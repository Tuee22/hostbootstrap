module OpenRootInvocationAuthority where

-- The safe facade does not expose the root kernel or caller-selected scope witness.

import HostBootstrap.Authority (
    withVerifiedRootInvocationKernel,
 )
