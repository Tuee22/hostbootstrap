module ProjectManagedPhaseWithoutAuthority where

import Data.Word (Word64)
import HostBootstrap.Reconcile

bad ::
    Word64 ->
    ResourceHandle scope planId id resource Managed Provisioned ->
    Either ReconcileError (ResourceHandle scope planId id resource Managed Running)
bad generation handle = freshManagedResourcePhase () generation handle
