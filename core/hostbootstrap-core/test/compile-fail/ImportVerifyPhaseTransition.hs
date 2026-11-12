module ImportVerifyPhaseTransition where

import Data.Word (Word64)
import HostBootstrap.Reconcile

-- DEVELOPMENT_PLAN/rationale.md#phase-advances-complete-a-prepared-pair
retained ::
    ResourceHandle scope planId id resource Managed fromPhase ->
    OwnershipReceipt scope planId id resource ->
    PhaseTransition scope planId id resource fromPhase toPhase ->
    Word64 ->
    Either ReconcileError (PhaseAdvance scope planId id resource toPhase)
retained = HostBootstrap.Reconcile.verifyPhaseTransition
