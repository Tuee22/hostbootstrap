-- | Downstream code uses public Reconcile exports, not the private declaration unit.
module ImportReconcileError where

import HostBootstrap.Reconcile.Error (ReconcileError)

bad :: Either ReconcileError ()
bad = Right ()
