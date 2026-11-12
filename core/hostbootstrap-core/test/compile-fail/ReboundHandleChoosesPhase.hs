module ReboundHandleChoosesPhase where

import HostBootstrap.Reconcile

requiresRunning :: ResourceHandle scope planId id resource Managed Running -> ()
requiresRunning _ = ()

bad ::
    PlannedResource scope planId id resource frame ->
    ResourceHandle scope planId oldId oldResource Managed Provisioned ->
    OwnershipReceipt scope planId oldId oldResource ->
    Either ReconcileError ()
bad planned handle receipt =
    withPlannedReboundManagedResourceEvidence planned handle receipt
        (\rebound _ -> requiresRunning rebound)
