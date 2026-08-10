{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Package-private terminal-close control for one live Harness run.

The public ownership handle existentially hides the run and broker brands.  This
indexed sub-handle is exposed only through that handle's rank-2 eliminator, so a
bound lease, close authorization, or settled-destroy proof from another run
cannot enter its state machine.  Callers can advance the state but cannot
provide the finalizer action: all close effects remain in
"HostBootstrap.Harness.Ownership".
-}
module HostBootstrap.Harness.Ownership.Internal (
    OwnedHarnessCloseControl,
    newOwnedHarnessCloseControl,
    beginOwnedHarnessBinding,
    armOwnedHarnessBoundClose,
    markOwnedHarnessClosePending,
    settleOwnedHarnessClose,
    consumeOwnedHarnessClose,
) where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import HostBootstrap.Lifecycle.Closure (
    ProductionCloseKind (PreEffectRefusalClose, SettledDestroyClose),
 )
import HostBootstrap.Lifecycle.Mode (
    BoundRunLease,
    HarnessCloseAuthorization,
    ProjectClosureEvidence,
    projectClosureEvidenceKind,
 )
import HostBootstrap.ProjectScope (Harness)

-- | The private monotone state of one live Harness root's terminal close.
data OwnedHarnessCloseState projectId runId brokerGeneration where
    OwnedHarnessCloseUnbound ::
        OwnedHarnessCloseState projectId runId brokerGeneration
    OwnedHarnessCloseBinding ::
        OwnedHarnessCloseState projectId runId brokerGeneration
    OwnedHarnessCloseBoundFallback ::
        BoundRunLease
            (Harness projectId runId)
            specDigest
            planDigest
            brokerGeneration ->
        OwnedHarnessCloseState projectId runId brokerGeneration
    OwnedHarnessClosePending ::
        HarnessCloseAuthorization projectId runId ->
        OwnedHarnessCloseState projectId runId brokerGeneration
    OwnedHarnessCloseSettled ::
        HarnessCloseAuthorization projectId runId ->
        OwnedHarnessCloseState projectId runId brokerGeneration
    OwnedHarnessCloseConsumed ::
        OwnedHarnessCloseState projectId runId brokerGeneration

{- | Opaque, one-run terminal-close control. Its nominal indices prevent a
caller from coercing authority between project, run, or broker brands.
-}
newtype OwnedHarnessCloseControl projectId runId brokerGeneration
    = OwnedHarnessCloseControl
        (IORef (OwnedHarnessCloseState projectId runId brokerGeneration))

type role OwnedHarnessCloseControl nominal nominal nominal

newOwnedHarnessCloseControl ::
    IO (OwnedHarnessCloseControl projectId runId brokerGeneration)
newOwnedHarnessCloseControl =
    OwnedHarnessCloseControl <$> newIORef OwnedHarnessCloseUnbound

{- | Enter the fail-closed sentinel immediately before attempting the durable
unbound-to-bound transition. An interruption cannot then route a possibly
bound lease through the unbound short close.
-}
beginOwnedHarnessBinding ::
    OwnedHarnessCloseControl projectId runId brokerGeneration ->
    IO (Either String ())
beginOwnedHarnessBinding control =
    transition control $ \current -> case current of
        OwnedHarnessCloseUnbound ->
            (OwnedHarnessCloseBinding, Right ())
        _ -> refused current "begin plan binding"

{- | Retain the exact bound lease as the true-pre-effect fallback. This is the
only successful successor of the binding sentinel.
-}
armOwnedHarnessBoundClose ::
    OwnedHarnessCloseControl projectId runId brokerGeneration ->
    BoundRunLease
        (Harness projectId runId)
        specDigest
        planDigest
        brokerGeneration ->
    IO (Either String ())
armOwnedHarnessBoundClose control bound =
    transition control $ \current -> case current of
        OwnedHarnessCloseBinding ->
            (OwnedHarnessCloseBoundFallback bound, Right ())
        _ -> refused current "arm the bound pre-effect fallback"

{- | Record the exact persisted Closing authorization before terminal
settlement. The pending state is deliberately not finalizable: interruption
here belongs to persisted-close recovery, never to the pre-effect short close.
-}
markOwnedHarnessClosePending ::
    OwnedHarnessCloseControl projectId runId brokerGeneration ->
    HarnessCloseAuthorization projectId runId ->
    IO (Either String ())
markOwnedHarnessClosePending control authorization =
    transition control $ \current -> case current of
        OwnedHarnessCloseBoundFallback _ ->
            (OwnedHarnessClosePending authorization, Right ())
        _ -> refused current "record pending terminal close"

{- | Admit terminal finalization only after the exact Harness scope has a
settled-destroy proof. The pending authorization is retained internally; a
caller cannot replace it or supply an action that merely reports success.
-}
settleOwnedHarnessClose ::
    OwnedHarnessCloseControl projectId runId brokerGeneration ->
    ProjectClosureEvidence (Harness projectId runId) ->
    IO (Either String ())
settleOwnedHarnessClose control evidence =
    case projectClosureEvidenceKind evidence of
        PreEffectRefusalClose ->
            pure
                ( Left
                    "the Harness terminal close requires settled-destroy evidence"
                )
        SettledDestroyClose ->
            transition control $ \current -> case current of
                OwnedHarnessClosePending authorization ->
                    (OwnedHarnessCloseSettled authorization, Right ())
                _ -> refused current "settle terminal close"

{- | Consume the control exactly once and dispatch only trusted authority to
the ownership finalizer. Binding and pending states fail closed without running
any close effect.
-}
consumeOwnedHarnessClose ::
    OwnedHarnessCloseControl projectId runId brokerGeneration ->
    IO (Either String ()) ->
    ( forall specDigest planDigest.
      BoundRunLease
        (Harness projectId runId)
        specDigest
        planDigest
        brokerGeneration ->
      IO (Either String ())
    ) ->
    (HarnessCloseAuthorization projectId runId -> IO (Either String ())) ->
    IO (Either String ())
consumeOwnedHarnessClose (OwnedHarnessCloseControl stateRef) closeUnbound closeBound closeSettled = do
    dispatch <- atomicModifyIORef' stateRef consumeState
    case dispatch of
        Left failure -> pure (Left failure)
        Right OwnedHarnessCloseDispatchUnbound -> closeUnbound
        Right (OwnedHarnessCloseDispatchBound bound) -> closeBound bound
        Right (OwnedHarnessCloseDispatchSettled authorization) ->
            closeSettled authorization

consumeState ::
    OwnedHarnessCloseState projectId runId brokerGeneration ->
    ( OwnedHarnessCloseState projectId runId brokerGeneration
    , Either String (OwnedHarnessCloseDispatch projectId runId brokerGeneration)
    )
consumeState current = case current of
    OwnedHarnessCloseUnbound ->
        (OwnedHarnessCloseConsumed, Right OwnedHarnessCloseDispatchUnbound)
    OwnedHarnessCloseBinding ->
        ( OwnedHarnessCloseConsumed
        , Left
            "the Harness plan binding did not yield its exact bound close fallback"
        )
    OwnedHarnessCloseBoundFallback bound ->
        ( OwnedHarnessCloseConsumed
        , Right (OwnedHarnessCloseDispatchBound bound)
        )
    OwnedHarnessClosePending _ ->
        ( OwnedHarnessCloseConsumed
        , Left
            "the Harness terminal close is persisted but its settled-destroy handoff did not complete; recovery is required"
        )
    OwnedHarnessCloseSettled authorization ->
        ( OwnedHarnessCloseConsumed
        , Right (OwnedHarnessCloseDispatchSettled authorization)
        )
    OwnedHarnessCloseConsumed ->
        ( OwnedHarnessCloseConsumed
        , Left "the Harness terminal close control was already consumed"
        )

data OwnedHarnessCloseDispatch projectId runId brokerGeneration where
    OwnedHarnessCloseDispatchUnbound ::
        OwnedHarnessCloseDispatch projectId runId brokerGeneration
    OwnedHarnessCloseDispatchBound ::
        BoundRunLease
            (Harness projectId runId)
            specDigest
            planDigest
            brokerGeneration ->
        OwnedHarnessCloseDispatch projectId runId brokerGeneration
    OwnedHarnessCloseDispatchSettled ::
        HarnessCloseAuthorization projectId runId ->
        OwnedHarnessCloseDispatch projectId runId brokerGeneration

transition ::
    OwnedHarnessCloseControl projectId runId brokerGeneration ->
    ( OwnedHarnessCloseState projectId runId brokerGeneration ->
      (OwnedHarnessCloseState projectId runId brokerGeneration, Either String ())
    ) ->
    IO (Either String ())
transition (OwnedHarnessCloseControl stateRef) advance =
    atomicModifyIORef' stateRef advance

refused ::
    OwnedHarnessCloseState projectId runId brokerGeneration ->
    String ->
    (OwnedHarnessCloseState projectId runId brokerGeneration, Either String ())
refused current attempted =
    ( current
    , Left
        ( "cannot "
            <> attempted
            <> " while the Harness terminal close control is "
            <> stateName current
        )
    )

stateName :: OwnedHarnessCloseState projectId runId brokerGeneration -> String
stateName current = case current of
    OwnedHarnessCloseUnbound -> "unbound"
    OwnedHarnessCloseBinding -> "binding"
    OwnedHarnessCloseBoundFallback _ -> "bound"
    OwnedHarnessClosePending _ -> "closing-pending"
    OwnedHarnessCloseSettled _ -> "settled"
    OwnedHarnessCloseConsumed -> "consumed"
