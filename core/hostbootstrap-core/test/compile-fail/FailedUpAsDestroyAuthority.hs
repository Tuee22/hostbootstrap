module FailedUpAsDestroyAuthority where

import HostBootstrap.Authority (RootInvocationAuthority, VerbDestroy)
import HostBootstrap.Authority.FailedUp.Internal (FailedUpUnwindAuthority)

needsDestroy :: RootInvocationAuthority scope generation VerbDestroy -> ()
needsDestroy _ = ()

cannotDestroy :: FailedUpUnwindAuthority scope plan generation catalog -> ()
cannotDestroy = needsDestroy
