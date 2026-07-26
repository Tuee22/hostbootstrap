module RawReconcile where

import HostBootstrap.Reconcile

badHandle :: ResourceHandle scope planId id resource Managed Observed
badHandle = ResourceHandle "resource" 1 1

badReceipt :: OwnershipReceipt scope planId id resource
badReceipt = OwnershipReceipt "resource" 1 "operation"
