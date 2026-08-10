{- | The prepared operation and its preconditions must carry the same hidden
operation and attempt identities.  A caller cannot pair halves from different
preparations even when every public byte is otherwise unavailable.
-}
module MismatchPreparedPairRoles where

import HostBootstrap.Reconcile
    ( BackendReconcileObservation (BackendCreated)
    , Observed
    , PreparedOperation
    , PreparedPreconditions
    , Provisioned
    , ReconcileError
    , ReconcileResult
    , ResourceHandle
    , Unclassified
    , completeReconcile
    )

data PairScope
data PairPlan
data PairIdentity
data PairResource
data PairCallDigest
data PairJournalVersion
data PairOperationA
data PairOperationB
data PairAttemptA
data PairAttemptB

mismatchedOperation ::
    ResourceHandle PairScope PairPlan PairIdentity PairResource Unclassified Observed ->
    PreparedOperation
        PairScope
        PairPlan
        PairIdentity
        PairResource
        PairOperationA
        PairCallDigest
        PairAttemptA
        PairJournalVersion ->
    PreparedPreconditions
        PairScope
        PairPlan
        PairIdentity
        PairResource
        PairOperationB
        PairCallDigest
        PairAttemptA
        PairJournalVersion ->
    Either
        ReconcileError
        (ReconcileResult PairScope PairPlan PairIdentity PairResource Provisioned)
mismatchedOperation handle prepared preconditions =
    completeReconcile handle prepared preconditions (BackendCreated 1)

mismatchedAttempt ::
    ResourceHandle PairScope PairPlan PairIdentity PairResource Unclassified Observed ->
    PreparedOperation
        PairScope
        PairPlan
        PairIdentity
        PairResource
        PairOperationA
        PairCallDigest
        PairAttemptA
        PairJournalVersion ->
    PreparedPreconditions
        PairScope
        PairPlan
        PairIdentity
        PairResource
        PairOperationA
        PairCallDigest
        PairAttemptB
        PairJournalVersion ->
    Either
        ReconcileError
        (ReconcileResult PairScope PairPlan PairIdentity PairResource Provisioned)
mismatchedAttempt handle prepared preconditions =
    completeReconcile handle prepared preconditions (BackendCreated 1)
