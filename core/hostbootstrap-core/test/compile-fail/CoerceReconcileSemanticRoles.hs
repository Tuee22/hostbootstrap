{- | Hidden semantic identities on public reconciliation evidence are nominal.
In particular, a prepared half cannot be relabeled to agree with another
operation or attempt merely because both store the same runtime field types.
-}
module CoerceReconcileSemanticRoles where

import Data.Coerce (coerce)
import HostBootstrap.Reconcile
    ( AdoptionAuthority
    , PhaseAdvance
    , PreparedOperation
    , PreparedPreconditions
    , VerifiedAtPhase
    , VerifiedForeignOrigin
    )

data Scope
data Plan
data Identity
data Resource

data ForeignOriginA
data ForeignOriginB
data AdoptionOriginA
data AdoptionOriginB
data AdoptionOperationA
data AdoptionOperationB
data PreparedOperationKeyA
data PreparedOperationKeyB
data PreparedOperationCallA
data PreparedOperationCallB
data PreparedOperationAttemptA
data PreparedOperationAttemptB
data PreparedOperationJournalA
data PreparedOperationJournalB
data PreparedPreconditionsKeyA
data PreparedPreconditionsKeyB
data PreparedPreconditionsCallA
data PreparedPreconditionsCallB
data PreparedPreconditionsAttemptA
data PreparedPreconditionsAttemptB
data PreparedPreconditionsJournalA
data PreparedPreconditionsJournalB
data VerifiedPhaseA
data VerifiedPhaseB
data AdvancePhaseA
data AdvancePhaseB

coerceForeignOrigin ::
    VerifiedForeignOrigin Scope Plan Identity Resource ForeignOriginA ->
    VerifiedForeignOrigin Scope Plan Identity Resource ForeignOriginB
coerceForeignOrigin = coerce

coerceAdoptionOrigin ::
    AdoptionAuthority Scope Plan Identity Resource AdoptionOriginA AdoptionOperationA ->
    AdoptionAuthority Scope Plan Identity Resource AdoptionOriginB AdoptionOperationA
coerceAdoptionOrigin = coerce

coerceAdoptionOperation ::
    AdoptionAuthority Scope Plan Identity Resource AdoptionOriginA AdoptionOperationA ->
    AdoptionAuthority Scope Plan Identity Resource AdoptionOriginA AdoptionOperationB
coerceAdoptionOperation = coerce

type BaselinePreparedOperation =
    PreparedOperation
        Scope
        Plan
        Identity
        Resource
        PreparedOperationKeyA
        PreparedOperationCallA
        PreparedOperationAttemptA
        PreparedOperationJournalA

coercePreparedOperationKey ::
    BaselinePreparedOperation ->
    PreparedOperation
        Scope
        Plan
        Identity
        Resource
        PreparedOperationKeyB
        PreparedOperationCallA
        PreparedOperationAttemptA
        PreparedOperationJournalA
coercePreparedOperationKey = coerce

coercePreparedOperationCall ::
    BaselinePreparedOperation ->
    PreparedOperation
        Scope
        Plan
        Identity
        Resource
        PreparedOperationKeyA
        PreparedOperationCallB
        PreparedOperationAttemptA
        PreparedOperationJournalA
coercePreparedOperationCall = coerce

coercePreparedOperationAttempt ::
    BaselinePreparedOperation ->
    PreparedOperation
        Scope
        Plan
        Identity
        Resource
        PreparedOperationKeyA
        PreparedOperationCallA
        PreparedOperationAttemptB
        PreparedOperationJournalA
coercePreparedOperationAttempt = coerce

coercePreparedOperationJournal ::
    BaselinePreparedOperation ->
    PreparedOperation
        Scope
        Plan
        Identity
        Resource
        PreparedOperationKeyA
        PreparedOperationCallA
        PreparedOperationAttemptA
        PreparedOperationJournalB
coercePreparedOperationJournal = coerce

type BaselinePreparedPreconditions =
    PreparedPreconditions
        Scope
        Plan
        Identity
        Resource
        PreparedPreconditionsKeyA
        PreparedPreconditionsCallA
        PreparedPreconditionsAttemptA
        PreparedPreconditionsJournalA

coercePreparedPreconditionsKey ::
    BaselinePreparedPreconditions ->
    PreparedPreconditions
        Scope
        Plan
        Identity
        Resource
        PreparedPreconditionsKeyB
        PreparedPreconditionsCallA
        PreparedPreconditionsAttemptA
        PreparedPreconditionsJournalA
coercePreparedPreconditionsKey = coerce

coercePreparedPreconditionsCall ::
    BaselinePreparedPreconditions ->
    PreparedPreconditions
        Scope
        Plan
        Identity
        Resource
        PreparedPreconditionsKeyA
        PreparedPreconditionsCallB
        PreparedPreconditionsAttemptA
        PreparedPreconditionsJournalA
coercePreparedPreconditionsCall = coerce

coercePreparedPreconditionsAttempt ::
    BaselinePreparedPreconditions ->
    PreparedPreconditions
        Scope
        Plan
        Identity
        Resource
        PreparedPreconditionsKeyA
        PreparedPreconditionsCallA
        PreparedPreconditionsAttemptB
        PreparedPreconditionsJournalA
coercePreparedPreconditionsAttempt = coerce

coercePreparedPreconditionsJournal ::
    BaselinePreparedPreconditions ->
    PreparedPreconditions
        Scope
        Plan
        Identity
        Resource
        PreparedPreconditionsKeyA
        PreparedPreconditionsCallA
        PreparedPreconditionsAttemptA
        PreparedPreconditionsJournalB
coercePreparedPreconditionsJournal = coerce

coerceVerifiedPhase ::
    VerifiedAtPhase Scope Plan Identity Resource VerifiedPhaseA ->
    VerifiedAtPhase Scope Plan Identity Resource VerifiedPhaseB
coerceVerifiedPhase = coerce

coerceAdvancePhase ::
    PhaseAdvance Scope Plan Identity Resource AdvancePhaseA ->
    PhaseAdvance Scope Plan Identity Resource AdvancePhaseB
coerceAdvancePhase = coerce
