module RawReceiptAsRehydratedReceipt where

import HostBootstrap.Lifecycle.Session (RehydratedOwnershipReceipt)
import HostBootstrap.Reconcile (OwnershipReceipt)

recoverRaw :: OwnershipReceipt scope planId id resource -> RehydratedOwnershipReceipt scope planId id brokerGeneration
recoverRaw receipt = receipt
