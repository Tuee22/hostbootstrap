{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The protected operation session, fence rotation, and the prepare
compare-and-swap (§ EE, the operator-root-and-command-authority phase).

the canonical-quantities-and-reconcile-results phase landed the *pure* journal algebra in "HostBootstrap.Reconcile":
'Reconcile.withPreparedOperation' validates a dependency set and mints the
'Reconcile.PreparedOperation' \/ 'Reconcile.PreparedPreconditions' pair an
adapter needs. It originally took the journal version as an ordinary 'Word64'
the caller supplied, so nothing proved that version was ever observed, that it
was still current, or that any session was open — two concurrent invocations
could each pass @7@ and each receive a prepared pair for the same operation.
It now takes a 'PreparedGate' instead, whose sole producer is the durable
unknown-phase write this module performs
("HostBootstrap.Lifecycle.Prepared").

This module is the durable half that makes those indices real. Every state
transition here is a compare-and-swap in the protected store
("HostBootstrap.Protected"), so:

* a session opens only against the live broker generation and only when no older
  session is still Open, and opening advances the shared project-journal
  version;
* an operation's initial intent is added to one exact session atomically with
  the version advance, so neither an orphan intent nor a session member without
  a record can exist;
* a prepare re-reads the journal under the exclusive entry, revalidates the
  broker epoch, session, project state, current fence, and recorded phase,
  durably records the operation-specific *unknown* phase **before** returning,
  and consumes the journal version it observed. The consumed version cannot
  authorize a second prepare or a close;
* a terminal observation returns 'OperationAdvance', whose eliminator yields the
  adapter's result only together with the sole successor permit;
* closing proves every registered operation settled before the session record
  moves to Closed, so a close cannot race a prepare.

The fence protocol (@FenceIntentRecorded -> FenceOutcomeUnknown ->
FenceObserved@) is durable and idempotent: a crash between any two records
resumes the same proposed epoch rather than proposing a new one, and a permit
issued under a superseded fence is rejected.
-}
module HostBootstrap.Lifecycle.Session (
    -- * The project journal
    ProjectJournalState (..),
    ProjectPermit,
    ClosingProjectPermit,
    ClosedProjectPermit,
    projectPermitVersion,
    openProjectJournal,
    readProjectJournalState,
    beginClosingProject,
    recordClosedProject,

    -- * Completeness proofs
    VerifiedAllSessionsClosed,
    allSessionsClosedCount,
    allSessionsClosedPlanDigest,
    verifyAllSessionsClosed,

    -- * Operation sessions
    SessionId,
    sessionIdText,
    OperationSession,
    operationSessionId,
    openOperationSession,
    closeOperationSession,

    -- * Fences
    FencePhase (..),
    FenceEpoch,
    fenceEpochWord,
    establishInitialFence,
    rotateFence,
    currentFence,

    -- * Operation intent
    IntentOrigin (..),
    registerOperationIntent,

    -- * The prepare compare-and-swap
    PreparedGate,
    preparedGatePlan,
    preparedGateOperation,
    preparedGateFence,
    preparedGateAttempt,
    preparedGateJournalVersion,
    withPreparedGate,
    withStepPreparedGate,

    -- * Terminal acknowledgment
    OperationAdvance,
    acknowledgeOutcome,
    withOperationAdvance,

    -- * Recovery
    OperationDisposition (..),
    classifyRecordedPhase,
    RecoveredSessions,
    recoveredSessionCount,
    recoveredContinuableCount,
    recoverAbandonedSessions,

    -- * The old-permit fence set
    OldPermitsFenced,
    oldPermitsFencedPlanDigest,
    oldPermitsFencedFrom,
    oldPermitsFencedTo,
    oldPermitsFencedOperations,
    fenceOldPermits,

    -- * The session\/operation manifest
    ManifestSession,
    manifestSessionId,
    manifestSessionIsOpen,
    manifestSessionOperations,
    VerifiedSessionManifest,
    manifestPlanDigest,
    manifestSessions,
    manifestOperationCount,
    verifySessionManifest,

    -- * The recorded-session interpreter
    RecoveredOperation (..),
    InterpretedRecovery,
    interpretedRecoveryPlanDigest,
    interpretedRecoverySessions,
    interpretedRecoveryOperations,
    interpretRecordedSessions,

    -- * Current-broker admission
    CurrentBrokerSessionAdmission,
    admissionPlanDigest,
    admissionBrokerGeneration,
    admissionSessionCount,
    admissionOperationCount,
    admitCurrentBroker,

    -- * Failures
    SessionError (..),
    sessionErrorMessage,
) where

import Control.Monad (foldM)
import Data.ByteString (ByteString)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Authority (
    BrokerEpoch,
    brokerEpochWord,
 )
import HostBootstrap.Lifecycle.Execution (
    StepExecution,
    stepExecutionOperationKey,
    stepExecutionPlanDigest,
 )
import HostBootstrap.Lifecycle.Prepared (
    PreparedGate,
    decodeFields,
    encodeFields,
    preparedGateAttempt,
    preparedGateFence,
    preparedGateJournalVersion,
    preparedGateOperation,
    preparedGatePlan,
    preparedGateSession,
 )
import HostBootstrap.Lifecycle.Prepared.Internal (
    mintPreparedGate,
 )
import HostBootstrap.Lifecycle.Transaction (
    TransactionError (..),
    TransactionPermit,
    TransactionRecord,
    TransactionTarget,
    TxnKind (..),
    ensureTransactionCoordinator,
    operationTransactionTarget,
    projectTransactionTarget,
    readTransactionRecord,
    runLifecycleTransaction,
    sessionTransactionTarget,
    transactionErrorMessage,
    transactionPermitVersion,
    transactionRecordPayload,
    transactionRecordVersion,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    RecordKey,
    RecordVersion,
    recordKeyText,
    compareAndSwapProtectedRecord,
    listProtectedRecords,
    mkRecordKey,
    mkRecordName,
    protectedErrorMessage,
    readProtectedRecord,
    recordNameIdentity,
    recordVersionWord,
 )

-- ---------------------------------------------------------------------------
-- The project journal

{- | Whether the plan's journal is accepting new work. A closed project cannot
open a session, and a session cannot be opened and then discover the project was
closed underneath it, because both contend on the same record version.
-}
data ProjectJournalState
    = OpenProject
    | -- | Terminal close is under way, under this exact epoch. A run that
      -- crashed here resumes /this/ close rather than reopening work, so the
      -- epoch is part of the state and not a separate flag.
      ClosingProject Word64
    | ClosedProject
    deriving (Eq, Show)

{- | The sole successor permit for one Open project-journal version.

Every operation that advances the journal returns exactly one of these, and the
version inside it is the version the *next* operation must present. A retained
older permit therefore cannot authorize a second advance — the compare-and-swap
against its version fails.
-}
newtype ProjectPermit scope planId = ProjectPermit TransactionPermit

instance Show (ProjectPermit scope planId) where
    show (ProjectPermit permit) = "ProjectPermit " <> show (transactionPermitVersion permit)

{- | The sole permit for a project journal in its terminal Closing epoch.

This is deliberately a different type from 'ProjectPermit': close recovery may
resume with it, but no Open-state operation accepts it and therefore it cannot
reopen the project journal.
-}
newtype ClosingProjectPermit scope planId = ClosingProjectPermit TransactionPermit

instance Show (ClosingProjectPermit scope planId) where
    show (ClosingProjectPermit permit) =
        "ClosingProjectPermit " <> show (transactionPermitVersion permit)

-- | Proof that the project journal reached its terminal Closed state.
newtype ClosedProjectPermit scope planId = ClosedProjectPermit TransactionPermit

instance Show (ClosedProjectPermit scope planId) where
    show (ClosedProjectPermit permit) =
        "ClosedProjectPermit " <> show (transactionPermitVersion permit)

-- | The journal version this permit authorizes the next transition against.
projectPermitVersion :: ProjectPermit scope planId -> Word64
projectPermitVersion (ProjectPermit permit) = transactionPermitVersion permit

projectKey :: Text -> Either SessionError RecordKey
projectKey planDigest = do
    digest <- recordName planDigest
    keyFor ("project." <> digest)

keyFor :: Text -> Either SessionError RecordKey
keyFor raw = either (Left . SessionStoreFailure) Right (mkRecordKey raw)

-- | 'mkRecordName' in this module's failure type.
recordName :: Text -> Either SessionError Text
recordName raw = either (Left . SessionStoreFailure) Right (mkRecordName raw)

-- | The identity a record-name component denotes ('recordNameIdentity').
recordIdentity :: Text -> Text
recordIdentity = recordNameIdentity

transactionFailure :: TransactionError -> SessionError
transactionFailure failure = case failure of
    TransactionStoreFailure storeFailure -> SessionStoreFailure storeFailure
    TransactionStalePermit version -> SessionStaleProjectPermit version
    _ -> SessionTransactionFailure (transactionErrorMessage failure)

ensureCoordinator ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError TransactionPermit)
ensureCoordinator session planDigest =
    fmap (either (Left . transactionFailure) Right) (ensureTransactionCoordinator session planDigest)

runTransaction ::
    ProtectedSession session ->
    Text ->
    TransactionPermit ->
    TxnKind ->
    [TransactionTarget] ->
    IO (Either SessionError TransactionPermit)
runTransaction session planDigest permit kind targets =
    fmap
        (either (Left . transactionFailure) Right)
        (runLifecycleTransaction session planDigest permit kind targets)

{- | Open (or resume) the plan's project journal, returning the permit for its
current version. Idempotent: an already-open journal is observed, not
republished, so a re-invocation after a crash does not reset the version other
holders are contending on.
-}
openProjectJournal ::
    ProtectedSession session ->
    -- | plan digest
    Text ->
    IO (Either SessionError (ProjectPermit scope planId))
openProjectJournal session planDigest =
    case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            coordinator <- ensureCoordinator session planDigest
            case coordinator of
                Left failure -> pure (Left failure)
                Right permit -> do
                    observed <- readTransactionRecord session key
                    case observed of
                        Left failure -> pure (Left (transactionFailure failure))
                        Right (Just record) -> case decodeJournalState (transactionRecordPayload record) of
                            Just OpenProject -> pure (Right (ProjectPermit permit))
                            -- A closing or closed project accepts no new work:
                            -- the distinction matters to recovery, not to this
                            -- opener.
                            Just (ClosingProject _) -> pure (Left (SessionProjectClosing planDigest))
                            Just ClosedProject -> pure (Left (SessionProjectClosed planDigest))
                            Nothing -> pure (Left (SessionRecordCorrupt "project journal"))
                        Right Nothing -> do
                            advanced <-
                                runTransaction
                                    session
                                    planDigest
                                    permit
                                    TxnOpenProject
                                    [projectTransactionTarget key Nothing (encodeJournalState OpenProject)]
                            pure (ProjectPermit <$> advanced)

-- | Read the journal state without advancing it.
readProjectJournalState ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError ProjectJournalState)
readProjectJournalState session planDigest =
    case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            coordinator <- ensureCoordinator session planDigest
            case coordinator of
                Left failure -> pure (Left failure)
                Right _ -> do
                    observed <- readTransactionRecord session key
                    pure $ case observed of
                        Left failure -> Left (transactionFailure failure)
                        Right Nothing -> Left (SessionProjectMissing planDigest)
                        Right (Just record) ->
                            maybe
                                (Left (SessionRecordCorrupt "project journal"))
                                Right
                                (decodeJournalState (transactionRecordPayload record))

{- | Revalidate an Open-state permit before mutating any operation or session
record.

The protected entry excludes other store holders for the lifetime of the
caller, so this read establishes that the later operation-record write is not
being driven by an already-consumed or Closing permit. In particular, a stale
prepare returns before 'recordDurableUnknown' can change the operation phase.
-}
withCurrentOpenPermit ::
    ProtectedSession session ->
    Text ->
    TransactionPermit ->
    IO (Either SessionError result) ->
    IO (Either SessionError result)
withCurrentOpenPermit session planDigest presented action =
    case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            coordinator <- ensureCoordinator session planDigest
            case coordinator of
                Left failure -> pure (Left failure)
                Right live -> do
                    observed <- readTransactionRecord session key
                    case observed of
                        Left failure -> pure (Left (transactionFailure failure))
                        Right Nothing -> pure (Left (SessionProjectMissing planDigest))
                        Right (Just record) ->
                            case decodeJournalState (transactionRecordPayload record) of
                                Nothing -> pure (Left (SessionRecordCorrupt "project journal"))
                                Just ClosedProject -> pure (Left (SessionProjectClosed planDigest))
                                Just (ClosingProject _) -> pure (Left (SessionProjectClosing planDigest))
                                Just OpenProject
                                    | transactionPermitVersion live /= transactionPermitVersion presented ->
                                        pure
                                            ( Left
                                                ( SessionStaleProjectPermit
                                                    (transactionPermitVersion presented)
                                                )
                                            )
                                    | otherwise -> action

encodeJournalState :: ProjectJournalState -> ByteString
encodeJournalState state = case state of
    OpenProject -> encodeFields ["open"]
    ClosingProject epoch -> encodeFields ["closing", Text.pack (show epoch)]
    ClosedProject -> encodeFields ["closed"]

decodeJournalState :: ByteString -> Maybe ProjectJournalState
decodeJournalState raw = case decodeFields raw of
    ["open"] -> Just OpenProject
    ["closed"] -> Just ClosedProject
    ["closing", epoch] -> do
        value <- readWord epoch
        if value == 0 then Nothing else Just (ClosingProject value)
    _ -> Nothing

{- | Move the project journal from Open to a fresh Closing epoch, against the
caller's exact permit version.

Session opening advances that same record, so a close and a concurrent
session-open contend on one version and exactly one wins. That is what makes
"a prepare cannot slip in after close was authorized" a compare-and-swap result
rather than an ordering hope.
-}
beginClosingProject ::
    ProtectedSession session ->
    -- | plan digest
    Text ->
    -- | the closing epoch; must be positive
    Word64 ->
    ProjectPermit scope planId ->
    IO (Either SessionError (ClosingProjectPermit scope planId))
beginClosingProject session planDigest epoch (ProjectPermit presented)
    | epoch == 0 = pure (Left (SessionRecordCorrupt "closing epoch must be positive"))
    | otherwise = case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            coordinator <- ensureCoordinator session planDigest
            case coordinator of
                Left failure -> pure (Left failure)
                Right live -> do
                    observed <- readTransactionRecord session key
                    case observed of
                        Left failure -> pure (Left (transactionFailure failure))
                        Right Nothing -> pure (Left (SessionProjectMissing planDigest))
                        Right (Just record) -> case decodeJournalState (transactionRecordPayload record) of
                            Nothing -> pure (Left (SessionRecordCorrupt "project journal"))
                            Just ClosedProject -> pure (Left (SessionProjectClosed planDigest))
                            -- Resuming the same persisted Closing epoch is
                            -- idempotent; a different one is a second close.
                            Just (ClosingProject persisted)
                                | persisted == epoch -> pure (Right (ClosingProjectPermit live))
                                | otherwise -> pure (Left (SessionProjectClosing planDigest))
                            Just OpenProject
                                | transactionPermitVersion live /= transactionPermitVersion presented ->
                                    pure (Left (SessionStaleProjectPermit (transactionPermitVersion presented)))
                                | otherwise -> do
                                    advanced <-
                                        runTransaction
                                            session
                                            planDigest
                                            presented
                                            TxnBeginProjectClose
                                            [ projectTransactionTarget
                                                key
                                                (Just record)
                                                (encodeJournalState (ClosingProject epoch))
                                            ]
                                    pure (ClosingProjectPermit <$> advanced)

{- | Record the terminal @ClosedProject@ state, only from the exact Closing
epoch that authorized it. An Open journal cannot jump straight to Closed.
-}
recordClosedProject ::
    ProtectedSession session ->
    Text ->
    -- | the closing epoch recorded by 'beginClosingProject'
    Word64 ->
    ClosingProjectPermit scope planId ->
    IO (Either SessionError (ClosedProjectPermit scope planId))
recordClosedProject session planDigest epoch (ClosingProjectPermit presented) =
    case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            coordinator <- ensureCoordinator session planDigest
            case coordinator of
                Left failure -> pure (Left failure)
                Right live -> do
                    observed <- readTransactionRecord session key
                    case observed of
                        Left failure -> pure (Left (transactionFailure failure))
                        Right Nothing -> pure (Left (SessionProjectMissing planDigest))
                        Right (Just record) -> case decodeJournalState (transactionRecordPayload record) of
                            Nothing -> pure (Left (SessionRecordCorrupt "project journal"))
                            Just ClosedProject -> pure (Right (ClosedProjectPermit live))
                            Just OpenProject -> pure (Left (SessionRecordCorrupt "project is not closing"))
                            Just (ClosingProject persisted)
                                | persisted /= epoch -> pure (Left (SessionProjectClosing planDigest))
                                | transactionPermitVersion live /= transactionPermitVersion presented ->
                                    pure (Left (SessionStaleProjectPermit (transactionPermitVersion presented)))
                                | otherwise -> do
                                    advanced <-
                                        runTransaction
                                            session
                                            planDigest
                                            presented
                                            TxnRecordProjectClosed
                                            [ projectTransactionTarget
                                                key
                                                (Just record)
                                                (encodeJournalState ClosedProject)
                                            ]
                                    pure (ClosedProjectPermit <$> advanced)

{- | Proof that every session for a plan was observed Closed at one store
version, with the count it covered.

Its constructor is private, and it enumerates the complete set rather than
accepting one the caller supplies: a zero-operation Open session is still a
member, which is exactly the state an invocation killed right after opening
leaves behind.
-}
data VerifiedAllSessionsClosed scope planId
    = VerifiedAllSessionsClosed Text Int

instance Show (VerifiedAllSessionsClosed scope planId) where
    show (VerifiedAllSessionsClosed plan n) =
        "VerifiedAllSessionsClosed " <> show plan <> " " <> show n

allSessionsClosedCount :: VerifiedAllSessionsClosed scope planId -> Int
allSessionsClosedCount (VerifiedAllSessionsClosed _ n) = n

{- | The plan digest this proof was taken over. The phantom indices alone would
let a proof taken for one plan be presented for another, so consumers compare
this against the bound lease's digest.
-}
allSessionsClosedPlanDigest :: VerifiedAllSessionsClosed scope planId -> Text
allSessionsClosedPlanDigest (VerifiedAllSessionsClosed plan _) = plan

verifyAllSessionsClosed ::
    ProtectedSession session ->
    -- | plan digest
    Text ->
    IO (Either SessionError (VerifiedAllSessionsClosed scope planId))
verifyAllSessionsClosed session planDigest = do
    coordinator <- ensureCoordinator session planDigest
    case coordinator of
        Left failure -> pure (Left failure)
        Right _ -> do
            listed <- listProtectedRecords session
            case listed of
                Left failure -> pure (Left (SessionStoreFailure failure))
                Right keys -> case sessionKeyPrefixFor planDigest of
                  Left failure -> pure (Left failure)
                  Right prefix -> do
                    let members =
                            [ SessionId (recordIdentity (Text.drop (Text.length prefix) raw))
                            | raw <- map recordKeyText keys
                            , prefix `Text.isPrefixOf` raw
                            ]
                    open <- foldM step (Right []) members
                    pure $ case open of
                        Left failure -> Left failure
                        Right (still : _) -> Left (SessionStillOpen still)
                        Right [] -> Right (VerifiedAllSessionsClosed planDigest (length members))
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) sid = do
        state <- readSessionState session planDigest sid
        pure $ case state of
            Left failure -> Left failure
            Right True -> Right (sid : acc)
            Right False -> Right acc

-- ---------------------------------------------------------------------------
-- Sessions

-- | A session's durable identifier.
newtype SessionId = SessionId Text
    deriving (Eq, Ord, Show)

sessionIdText :: SessionId -> Text
sessionIdText (SessionId value) = value

{- | One open operation session. Opaque: it exists only as the result of
'openOperationSession', which proved the broker generation current and no older
session Open.
-}
data OperationSession scope planId = OperationSession
    { sessionRecordId :: SessionId
    , sessionPlanDigest :: Text
    , sessionBrokerGeneration :: Word64
    }

instance Show (OperationSession scope planId) where
    show sess = "OperationSession " <> show (sessionRecordId sess)

operationSessionId :: OperationSession scope planId -> SessionId
operationSessionId = sessionRecordId

sessionKey :: Text -> SessionId -> Either SessionError RecordKey
sessionKey planDigest (SessionId sid) = do
    prefix <- sessionKeyPrefixFor planDigest
    name <- recordName sid
    keyFor (prefix <> name)

sessionKeyPrefixFor :: Text -> Either SessionError Text
sessionKeyPrefixFor planDigest = do
    digest <- recordName planDigest
    pure ("session." <> digest <> ".")

data SessionRecordState = SessionRecordState
    { sessionRecordIsOpen :: Bool
    , sessionRecordMarker :: Text
    , sessionRecordMembers :: [Text]
    , sessionRecordHasExactMembership :: Bool
    }
    deriving (Eq, Show)

encodeSessionRecord :: Bool -> Text -> [Text] -> ByteString
encodeSessionRecord isOpen marker members =
    encodeFields
        ( (if isOpen then "open" else "closed")
            : marker
            : "members"
            : sort members
        )

decodeSessionRecord :: ByteString -> Maybe SessionRecordState
decodeSessionRecord raw = case decodeFields raw of
    [phase, marker]
        | phase == "open" || phase == "closed" ->
            Just
                SessionRecordState
                    { sessionRecordIsOpen = phase == "open"
                    , sessionRecordMarker = marker
                    , sessionRecordMembers = []
                    , sessionRecordHasExactMembership = False
                    }
    (phase : marker : "members" : members)
        | phase == "open" || phase == "closed" ->
            Just
                SessionRecordState
                    { sessionRecordIsOpen = phase == "open"
                    , sessionRecordMarker = marker
                    , sessionRecordMembers = sort members
                    , sessionRecordHasExactMembership = True
                    }
    _ -> Nothing

readSessionRecord ::
    ProtectedSession session ->
    Text ->
    SessionId ->
    IO (Either SessionError (Maybe (TransactionRecord, SessionRecordState)))
readSessionRecord session planDigest sid =
    case sessionKey planDigest sid of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readTransactionRecord session key
            pure $ case observed of
                Left failure -> Left (transactionFailure failure)
                Right Nothing -> Right Nothing
                Right (Just record) ->
                    case decodeSessionRecord (transactionRecordPayload record) of
                        Nothing -> Left (SessionRecordCorrupt "session")
                        Just state -> Right (Just (record, state))

legacyOperationNames ::
    ProtectedSession session ->
    Text ->
    SessionId ->
    IO (Either SessionError [Text])
legacyOperationNames session planDigest sid = do
    listed <- listProtectedRecords session
    pure $ case (listed, operationPrefixFor planDigest sid) of
        (Left failure, _) -> Left (SessionStoreFailure failure)
        (_, Left failure) -> Left failure
        (Right keys, Right prefix) ->
            Right
                ( sort
                    [ recordIdentity (Text.drop (Text.length prefix) raw)
                    | raw <- map recordKeyText keys
                    , prefix `Text.isPrefixOf` raw
                    ]
                )

sessionOperationNames ::
    ProtectedSession session ->
    Text ->
    SessionId ->
    SessionRecordState ->
    IO (Either SessionError [Text])
sessionOperationNames session planDigest sid state
    | sessionRecordHasExactMembership state = pure (Right (sessionRecordMembers state))
    | otherwise = legacyOperationNames session planDigest sid

{- | Open a session for this plan against the live broker generation.

Refuses when the project journal is closed, when the caller's permit is not the
current journal version (someone else advanced it first), or when any older
session for this plan is still Open — including a session that registered no
operations at all, which is exactly the state an invocation killed immediately
after opening leaves behind.
-}
openOperationSession ::
    ProtectedSession session ->
    BrokerEpoch brokerGeneration ->
    -- | plan digest
    Text ->
    -- | this session's identifier
    Text ->
    ProjectPermit scope planId ->
    IO (Either SessionError (OperationSession scope planId, ProjectPermit scope planId))
openOperationSession session epoch planDigest rawSessionId (ProjectPermit presented) = do
    let sid = SessionId rawSessionId
    recovered <- ensureCoordinator session planDigest
    case recovered of
        Left failure -> pure (Left failure)
        Right _ -> do
            stale <- openSessionsFor session planDigest
            case stale of
                Left failure -> pure (Left failure)
                Right (older : _) -> pure (Left (SessionOlderStillOpen older))
                Right [] -> case sessionKey planDigest sid of
                    Left failure -> pure (Left failure)
                    Right sKey ->
                        withCurrentOpenPermit session planDigest presented $ do
                            observed <- readTransactionRecord session sKey
                            case observed of
                                Left failure -> pure (Left (transactionFailure failure))
                                Right (Just _) -> pure (Left (SessionNotOpen sid))
                                Right Nothing -> do
                                    advanced <-
                                        runTransaction
                                            session
                                            planDigest
                                            presented
                                            TxnOpenSession
                                            [ sessionTransactionTarget
                                                sKey
                                                Nothing
                                                ( encodeSessionRecord
                                                    True
                                                    (Text.pack (show (brokerEpochWord epoch)))
                                                    []
                                                )
                                            ]
                                    pure $ do
                                        next <- advanced
                                        Right
                                            ( OperationSession
                                                { sessionRecordId = sid
                                                , sessionPlanDigest = planDigest
                                                , sessionBrokerGeneration = brokerEpochWord epoch
                                                }
                                            , ProjectPermit next
                                            )

-- | Every session record for this plan that is still Open.
openSessionsFor ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError [SessionId])
openSessionsFor session planDigest = do
    listed <- listProtectedRecords session
    case listed of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right keys -> case sessionKeyPrefixFor planDigest of
          Left failure -> pure (Left failure)
          Right prefix -> do
            let candidates =
                    [ SessionId (recordIdentity (Text.drop (Text.length prefix) raw))
                    | raw <- map recordKeyText keys
                    , prefix `Text.isPrefixOf` raw
                    ]
            foldM step (Right []) candidates
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) sid = do
        state <- readSessionState session planDigest sid
        pure $ case state of
            Left failure -> Left failure
            Right True -> Right (sid : acc)
            Right False -> Right acc

readSessionState ::
    ProtectedSession session ->
    Text ->
    SessionId ->
    IO (Either SessionError Bool)
readSessionState session planDigest sid =
    fmap
        (fmap (maybe False (sessionRecordIsOpen . snd)))
        (readSessionRecord session planDigest sid)

{- | Close a session, proving first that every operation it registered has
settled.

Closing contends on the same session record version a prepare would, so a close
and a concurrent prepare have exactly one winner: whichever loses the
compare-and-swap sees a stale version and refuses.
-}
closeOperationSession ::
    ProtectedSession session ->
    OperationSession scope planId ->
    ProjectPermit scope planId ->
    IO (Either SessionError (ProjectPermit scope planId))
closeOperationSession session sess (ProjectPermit presented) =
    withCurrentOpenPermit session (sessionPlanDigest sess) presented $ do
        unsettled <- unsettledOperations session sess
        case unsettled of
            Left failure -> pure (Left failure)
            Right (pending : _) -> pure (Left (SessionOperationUnsettled pending))
            Right [] -> case sessionKey (sessionPlanDigest sess) (sessionRecordId sess) of
                Left failure -> pure (Left failure)
                Right sKey -> do
                    observed <- readSessionRecord session (sessionPlanDigest sess) (sessionRecordId sess)
                    case observed of
                        Left failure -> pure (Left failure)
                        Right Nothing -> pure (Left (SessionUnknown (sessionRecordId sess)))
                        Right (Just (record, state))
                            | not (sessionRecordIsOpen state) ->
                                pure (Left (SessionNotOpen (sessionRecordId sess)))
                            | otherwise -> do
                                members <-
                                    sessionOperationNames
                                        session
                                        (sessionPlanDigest sess)
                                        (sessionRecordId sess)
                                        state
                                case members of
                                    Left failure -> pure (Left failure)
                                    Right names -> do
                                        advanced <-
                                            runTransaction
                                                session
                                                (sessionPlanDigest sess)
                                                presented
                                                TxnCloseSession
                                                [ sessionTransactionTarget
                                                    sKey
                                                    (Just record)
                                                    (encodeSessionRecord False (sessionRecordMarker state) names)
                                                ]
                                        pure (ProjectPermit <$> advanced)

-- ---------------------------------------------------------------------------
-- Operation records

operationKeyFor :: Text -> SessionId -> Text -> Either SessionError RecordKey
operationKeyFor planDigest (SessionId sid) opKey = do
    prefix <- operationPrefixFor planDigest (SessionId sid)
    name <- recordName opKey
    keyFor (prefix <> name)

operationPrefixFor :: Text -> SessionId -> Either SessionError Text
operationPrefixFor planDigest (SessionId sid) = do
    digest <- recordName planDigest
    name <- recordName sid
    pure ("op." <> digest <> "." <> name <> ".")

{- | Where an operation's first intent may legitimately come from: no prior
history at all, or a previous generation that was explicitly released.

An operation that already has a live record cannot re-register an initial
intent; it must continue from the phase it is in.
-}
data IntentOrigin
    = NoHistory
    | ReleasedReacquisition
    deriving (Eq, Show)

{- | Register an operation's initial intent, atomically joining it to this exact
session and advancing the project journal.

The two writes are ordered so neither an orphan intent (a record belonging to no
session) nor a recordless session member can exist: the operation record names
its session, and the journal advance is what makes the pair visible to the next
holder.
-}
registerOperationIntent ::
    ProtectedSession session ->
    OperationSession scope planId ->
    -- | the operation key
    Text ->
    IntentOrigin ->
    ProjectPermit scope planId ->
    IO (Either SessionError (ProjectPermit scope planId))
registerOperationIntent session sess opKey origin (ProjectPermit presented) =
    case (operationKeyFor plan (sessionRecordId sess) opKey, sessionKey plan (sessionRecordId sess)) of
        (Left failure, _) -> pure (Left failure)
        (_, Left failure) -> pure (Left failure)
        (Right oKey, Right sKey) ->
            withCurrentOpenPermit session plan presented $ do
                sessionObserved <- readSessionRecord session plan (sessionRecordId sess)
                case sessionObserved of
                    Left failure -> pure (Left failure)
                    Right Nothing -> pure (Left (SessionUnknown (sessionRecordId sess)))
                    Right (Just (_, state))
                        | not (sessionRecordIsOpen state) ->
                            pure (Left (SessionNotOpen (sessionRecordId sess)))
                    Right (Just (sessionRecord, state)) -> do
                        observed <- readTransactionRecord session oKey
                        case observed of
                            Left failure -> pure (Left (transactionFailure failure))
                            Right (Just record)
                                | origin == NoHistory ->
                                    pure
                                        ( Left
                                            ( SessionIntentAlreadyRecorded
                                                opKey
                                                (phaseTextOf (transactionRecordPayload record))
                                            )
                                        )
                                | phaseTextOf (transactionRecordPayload record) /= "Released" ->
                                    pure
                                        ( Left
                                            ( SessionIntentOriginRefused
                                                opKey
                                                (phaseTextOf (transactionRecordPayload record))
                                            )
                                        )
                            Right operationRecord -> do
                                existingMembers <-
                                    sessionOperationNames session plan (sessionRecordId sess) state
                                case existingMembers of
                                    Left failure -> pure (Left failure)
                                    Right members -> do
                                        let exactMembers =
                                                sort
                                                    ( if opKey `elem` members
                                                        then members
                                                        else opKey : members
                                                    )
                                        advanced <-
                                            runTransaction
                                                session
                                                plan
                                                presented
                                                TxnRegisterIntent
                                                [ operationTransactionTarget
                                                    oKey
                                                    operationRecord
                                                    ( encodeFields
                                                        [ "IntentRecorded"
                                                        , sessionIdText (sessionRecordId sess)
                                                        , "0"
                                                        ]
                                                    )
                                                , sessionTransactionTarget
                                                    sKey
                                                    (Just sessionRecord)
                                                    ( encodeSessionRecord
                                                        True
                                                        (sessionRecordMarker state)
                                                        exactMembers
                                                    )
                                                ]
                                        pure (ProjectPermit <$> advanced)
  where
    plan = sessionPlanDigest sess

phaseTextOf :: ByteString -> Text
phaseTextOf raw = case decodeFields raw of
    (phase : _) -> phase
    [] -> ""

recordedFenceOf :: ByteString -> Word64
recordedFenceOf raw = case decodeFields raw of
    (_ : _ : fence : _) -> maybe 0 id (readWord fence)
    _ -> 0

readWord :: Text -> Maybe Word64
readWord raw = case reads (Text.unpack raw) of
    [(value, "")] -> Just value
    _ -> Nothing

{- | Every operation in this session that has not reached a settled phase. Used
by 'closeOperationSession' to refuse a close that would strand work.
-}
unsettledOperations ::
    ProtectedSession session ->
    OperationSession scope planId ->
    IO (Either SessionError [Text])
unsettledOperations session sess = do
    sessionObserved <- readSessionRecord session (sessionPlanDigest sess) (sessionRecordId sess)
    case sessionObserved of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Left (SessionUnknown (sessionRecordId sess)))
        Right (Just (_, state)) -> do
            names <-
                sessionOperationNames
                    session
                    (sessionPlanDigest sess)
                    (sessionRecordId sess)
                    state
            case names of
                Left failure -> pure (Left failure)
                Right operationNames -> foldM step (Right []) operationNames
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) name =
        case operationKeyFor (sessionPlanDigest sess) (sessionRecordId sess) name of
            Left failure -> pure (Left failure)
            Right key -> do
                observed <- readTransactionRecord session key
                pure $ case observed of
                    Left failure -> Left (transactionFailure failure)
                    Right Nothing -> Right acc
                    Right (Just record) ->
                        case classifyRecordedPhase (phaseTextOf (transactionRecordPayload record)) of
                            Settled -> Right acc
                            TerminalDisposition -> Right acc
                            _ -> Right (name : acc)

-- ---------------------------------------------------------------------------
-- Fences

{- | The durable fence-rotation protocol.

A fence is proposed, then its outcome is unknown, then it is observed. The
middle state is the load-bearing one: a crash there must resume the *same*
proposed epoch rather than proposing a new one, because a delayed permit issued
under the proposal may still be in flight.
-}
data FencePhase
    = FenceIntentRecorded
    | FenceOutcomeUnknown
    | FenceObserved
    deriving (Eq, Show)

-- | An observed fence epoch. Only a 'FenceObserved' record produces one.
newtype FenceEpoch scope planId = FenceEpoch Word64

instance Show (FenceEpoch scope planId) where
    show (FenceEpoch value) = "FenceEpoch " <> show value

fenceEpochWord :: FenceEpoch scope planId -> Word64
fenceEpochWord (FenceEpoch value) = value

fenceKey :: Text -> Either SessionError RecordKey
fenceKey planDigest = do
    digest <- recordName planDigest
    keyFor ("fence." <> digest)

{- | Establish the plan's initial fence, or resume an interrupted establishment.

Idempotent by construction: the proposed epoch is written before it is used, so
a resume reads the proposal back rather than choosing a different one. An
interrupted run therefore converges on one epoch no matter how many times it is
restarted.
-}
establishInitialFence ::
    ProtectedSession session ->
    Text ->
    -- | the proposed epoch
    Word64
    ->
    IO (Either SessionError (FenceEpoch scope planId))
establishInitialFence session planDigest proposed
    | proposed == 0 = pure (Left (SessionFenceInvalid "a fence epoch must be positive"))
    | otherwise = case fenceKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (Left (SessionStoreFailure failure))
                Right Nothing -> do
                    -- Record the intent first; the epoch is durable before any
                    -- permit can be issued under it.
                    intent <-
                        compareAndSwapProtectedRecord
                            session
                            key
                            ExpectAbsent
                            (fenceRecord FenceIntentRecorded proposed)
                    case intent of
                        Left failure -> pure (Left (SessionStoreFailure failure))
                        Right version -> settleFence session key version proposed
                Right (Just record) ->
                    case decodeFenceRecord (protectedRecordBytes record) of
                        Nothing -> pure (Left (SessionRecordCorrupt "fence"))
                        -- Resume the persisted proposal, never the caller's.
                        Just (FenceIntentRecorded, persisted) ->
                            settleFence session key (protectedRecordVersion record) persisted
                        Just (FenceOutcomeUnknown, persisted) ->
                            settleFence session key (protectedRecordVersion record) persisted
                        Just (FenceObserved, persisted) -> pure (Right (FenceEpoch persisted))

settleFence ::
    ProtectedSession session ->
    RecordKey ->
    RecordVersion ->
    Word64 ->
    IO (Either SessionError (FenceEpoch scope planId))
settleFence session key version epoch = do
    unknown <-
        compareAndSwapProtectedRecord
            session
            key
            (ExpectVersion version)
            (fenceRecord FenceOutcomeUnknown epoch)
    case unknown of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right nextVersion -> do
            settled <-
                compareAndSwapProtectedRecord
                    session
                    key
                    (ExpectVersion nextVersion)
                    (fenceRecord FenceObserved epoch)
            pure $ case settled of
                Left failure -> Left (SessionStoreFailure failure)
                Right _ -> Right (FenceEpoch epoch)

{- | Rotate to a strictly greater fence epoch. A rotation to the same or a lower
epoch is refused, so a replayed rotation cannot reopen a superseded epoch.
-}
rotateFence ::
    ProtectedSession session ->
    Text ->
    FenceEpoch scope planId ->
    IO (Either SessionError (FenceEpoch scope planId))
rotateFence session planDigest (FenceEpoch previous) =
    case fenceKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (Left (SessionStoreFailure failure))
                Right Nothing -> pure (Left (SessionFenceMissing planDigest))
                Right (Just record) -> case decodeFenceRecord (protectedRecordBytes record) of
                    Nothing -> pure (Left (SessionRecordCorrupt "fence"))
                    Just (_, persisted)
                        | persisted /= previous ->
                            pure (Left (SessionFenceSuperseded previous persisted))
                        | otherwise -> do
                            intent <-
                                compareAndSwapProtectedRecord
                                    session
                                    key
                                    (ExpectVersion (protectedRecordVersion record))
                                    (fenceRecord FenceIntentRecorded (previous + 1))
                            case intent of
                                Left failure -> pure (Left (SessionStoreFailure failure))
                                Right version -> settleFence session key version (previous + 1)

-- | Read the current observed fence, if the protocol has settled one.
currentFence ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError (FenceEpoch scope planId))
currentFence session planDigest =
    case fenceKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord session key
            pure $ case observed of
                Left failure -> Left (SessionStoreFailure failure)
                Right Nothing -> Left (SessionFenceMissing planDigest)
                Right (Just record) -> case decodeFenceRecord (protectedRecordBytes record) of
                    Just (FenceObserved, epoch) -> Right (FenceEpoch epoch)
                    Just (phase, _) -> Left (SessionFenceUnsettled phase)
                    Nothing -> Left (SessionRecordCorrupt "fence")

fenceRecord :: FencePhase -> Word64 -> ByteString
fenceRecord phase epoch = encodeFields [fencePhaseText phase, Text.pack (show epoch)]

fencePhaseText :: FencePhase -> Text
fencePhaseText FenceIntentRecorded = "FenceIntentRecorded"
fencePhaseText FenceOutcomeUnknown = "FenceOutcomeUnknown"
fencePhaseText FenceObserved = "FenceObserved"

decodeFenceRecord :: ByteString -> Maybe (FencePhase, Word64)
decodeFenceRecord raw = case decodeFields raw of
    [phase, epoch] -> (,) <$> parsePhase phase <*> readWord epoch
    _ -> Nothing
  where
    parsePhase "FenceIntentRecorded" = Just FenceIntentRecorded
    parsePhase "FenceOutcomeUnknown" = Just FenceOutcomeUnknown
    parsePhase "FenceObserved" = Just FenceObserved
    parsePhase _ = Nothing

-- ---------------------------------------------------------------------------
-- Recovery classification

{- | The total discriminator every recorded operation phase falls into.

Totality is the point: recovery must decide something for every phase the
journal can hold, including a phase it does not recognise, and the decision
determines whether that operation may receive effect authority again.
-}
data OperationDisposition
    = -- | no record, or a phase this binary does not recognise
      UnknownDisposition
    | -- | a pre-call phase; may receive current-fence prepare authority
      Continuable
    | -- | an already-observed phase on the closed retry whitelist; may receive
      -- fenced same-key retry authority only
      FencedRetryable
    | -- | committed work; no further effect authority
      Settled
    | -- | a terminal branch (foreign, refused, unexpected); no effect authority
      TerminalDisposition
    deriving (Eq, Show)

{- | Classify a recorded phase name.

The five **continuable** pre-call phases are the ones where no effect has been
attempted yet, so re-preparing them under the current fence is safe. The
**fenced-retryable** set is the closed whitelist § EE names: an authoritative
absence of a reservation or effect, an ordinary or adopted same-identity
teardown observation, an adoption absence, a repair original, and a phase
observed *from* — each of which may retry only after crossing an explicit fenced
state. Everything committed is 'Settled', every foreign/refused/unexpected
branch is 'TerminalDisposition', and anything unrecognised is
'UnknownDisposition' rather than being optimistically treated as safe.
-}
classifyRecordedPhase :: Text -> OperationDisposition
classifyRecordedPhase phase
    | phase `elem` continuablePhases = Continuable
    | phase `elem` fencedRetryablePhases = FencedRetryable
    | phase `elem` settledPhases = Settled
    | phase `elem` terminalPhases = TerminalDisposition
    | otherwise = UnknownDisposition

continuablePhases :: [Text]
continuablePhases =
    [ "IntentRecorded"
    , "AdoptionIntentRecorded"
    , "RepairIntentRecorded"
    , "PhaseIntentRecorded"
    , "ReservationRetryFenced"
    ]

fencedRetryablePhases :: [Text]
fencedRetryablePhases =
    [ "ReservationAbsent"
    , "EffectAbsent"
    , "AdoptionObservedAbsent"
    , "RepairObservedOriginal"
    , "PhaseObservedFrom"
    , "EffectRetryFenced"
    , "AdoptionRetryFenced"
    , "RepairRetryFenced"
    , "PhaseRetryFenced"
    ]

settledPhases :: [Text]
settledPhases =
    [ "Committed"
    , "AdoptionCommitted"
    , "RepairCommitted"
    , "PhaseCommitted"
    , "Released"
    , "AdoptionReleased"
    ]

terminalPhases :: [Text]
terminalPhases =
    [ -- A chain node that returned a definite non-success observation: a
      -- conflict, an unsupported backend, or a safety refusal. All three are
      -- terminal for recovery in the same way — an operator resolves them, a
      -- successor may not retry them — so they settle at one phase. Which of the
      -- three it was is carried by the interpreter's row, not by the record,
      -- because the record's only job here is the recovery classification.
      "StepObservedTerminal"
    , -- What the recorded-session interpreter writes over an operation whose
      -- owning run was abandoned. It is terminal rather than continuable
      -- because the run that registered it is gone: a successor is a different
      -- run with its own session, and letting it inherit this operation's
      -- authority is exactly the replay the fence set exists to prevent. It is
      -- distinct from the other terminal phases so the journal still says *why*
      -- the operation stopped.
      "RecoveryAbandoned"
    , "ObservedForeign"
    , "TeardownObservedForeign"
    , "AdoptionObservedForeign"
    , "AdoptionRefused"
    , "RepairObservedForeign"
    , "RepairObservedUnexpected"
    , "PhaseObservedForeign"
    , "PhaseObservedUnexpected"
    ]

-- | What a recovery sweep settled.
data RecoveredSessions = RecoveredSessions
    { recoveredSessionCount :: Int
    , recoveredContinuableCount :: Int
    }
    deriving (Eq, Show)

{- | Close every Open session for this plan, classifying each of its operations.

This is what a new invocation runs before it may open its own session. It is
deliberately total over recorded phases: an operation whose phase this binary
does not recognise is 'UnknownDisposition' and blocks admission rather than
being swept as though it were finished.
-}
recoverAbandonedSessions ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError RecoveredSessions)
recoverAbandonedSessions session planDigest = do
    coordinator <- ensureCoordinator session planDigest
    case coordinator of
        Left failure -> pure (Left failure)
        Right initialPermit -> do
            listed <- openSessionsFor session planDigest
            case listed of
                Left failure -> pure (Left failure)
                Right sessions -> do
                    recovered <-
                        foldM
                            step
                            (Right (RecoveredSessions 0 0, initialPermit))
                            (sort sessions)
                    pure (fst <$> recovered)
  where
    step (Left failure) _ = pure (Left failure)
    step (Right (acc, permit)) sid = do
        counted <- classifySessionOperations session planDigest sid
        case counted of
            Left failure -> pure (Left failure)
            Right continuable -> case sessionKey planDigest sid of
                Left failure -> pure (Left failure)
                Right key -> do
                    observed <- readSessionRecord session planDigest sid
                    case observed of
                        Left failure -> pure (Left failure)
                        Right Nothing -> pure (Right (acc, permit))
                        Right (Just (record, state))
                            | not (sessionRecordIsOpen state) -> pure (Right (acc, permit))
                            | otherwise -> do
                                members <- sessionOperationNames session planDigest sid state
                                case members of
                                    Left failure -> pure (Left failure)
                                    Right names -> do
                                        closed <-
                                            runTransaction
                                                session
                                                planDigest
                                                permit
                                                TxnCloseSession
                                                [ sessionTransactionTarget
                                                    key
                                                    (Just record)
                                                    (encodeSessionRecord False "recovered" names)
                                                ]
                                        pure $ case closed of
                                            Left failure -> Left failure
                                            Right nextPermit ->
                                                Right
                                                    ( RecoveredSessions
                                                        { recoveredSessionCount =
                                                            recoveredSessionCount acc + 1
                                                        , recoveredContinuableCount =
                                                            recoveredContinuableCount acc + continuable
                                                        }
                                                    , nextPermit
                                                    )

classifySessionOperations ::
    ProtectedSession session ->
    Text ->
    SessionId ->
    IO (Either SessionError Int)
classifySessionOperations session planDigest sid = do
    observedSession <- readSessionRecord session planDigest sid
    case observedSession of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Right 0)
        Right (Just (_, state)) -> do
            names <- sessionOperationNames session planDigest sid state
            case names of
                Left failure -> pure (Left failure)
                Right operationNames -> foldM step (Right 0) operationNames
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) name = case operationKeyFor planDigest sid name of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readTransactionRecord session key
            pure $ case observed of
                Left failure -> Left (transactionFailure failure)
                Right Nothing -> Right acc
                Right (Just record) ->
                    case classifyRecordedPhase (phaseTextOf (transactionRecordPayload record)) of
                        UnknownDisposition ->
                            Left
                                ( SessionUnclassifiedPhase
                                    name
                                    (phaseTextOf (transactionRecordPayload record))
                                )
                        Continuable -> Right (acc + 1)
                        _ -> Right acc

-- ---------------------------------------------------------------------------
-- Abandoned-run recovery admission

{- | The exact set of permits the old broker generation could still be holding,
proved fenced out.

Its constructor is private and it carries the /enumerated/ operation keys rather
than a count, because § EE requires recovery to consume "the exact old-permit
fence set in a protected exact-set fold". A caller cannot present a set it chose:
'fenceOldPermits' reads the set out of the store and rotates the fence in the
same protected entry, so the set named here is exactly the set the rotation
superseded.

The two epochs are both retained. @from@ is what a delayed permit would carry and
@to@ is what the prepare gate will now demand, so the proof states the window it
closed instead of asserting that one was closed.
-}
data OldPermitsFenced scope planId
    = OldPermitsFenced Text Word64 Word64 [Text]

instance Show (OldPermitsFenced scope planId) where
    show (OldPermitsFenced plan from to keys) =
        "OldPermitsFenced "
            <> show plan
            <> " "
            <> show from
            <> " -> "
            <> show to
            <> " "
            <> show keys

-- | The plan digest this fencing was taken over.
oldPermitsFencedPlanDigest :: OldPermitsFenced scope planId -> Text
oldPermitsFencedPlanDigest (OldPermitsFenced plan _ _ _) = plan

-- | The superseded epoch — what a delayed old permit carries.
oldPermitsFencedFrom :: OldPermitsFenced scope planId -> Word64
oldPermitsFencedFrom (OldPermitsFenced _ from _ _) = from

-- | The epoch the prepare gate now demands.
oldPermitsFencedTo :: OldPermitsFenced scope planId -> Word64
oldPermitsFencedTo (OldPermitsFenced _ _ to _) = to

{- | The exact operation keys that were still able to receive authority under the
superseded epoch, in sorted order.
-}
oldPermitsFencedOperations :: OldPermitsFenced scope planId -> [Text]
oldPermitsFencedOperations (OldPermitsFenced _ _ _ keys) = keys

{- | Fence out every permit the abandoned generation could still be holding.

The order is the whole of the guarantee:

1. the fence protocol is /settled/ first. A run killed between proposing an epoch
   and observing it leaves @FenceIntentRecorded@ or @FenceOutcomeUnknown@, and
   § EE names that "an explicit recovery state" whose stable protocol recovery
   completes idempotently rather than proposing a fresh epoch beside it.
   'establishInitialFence' is exactly that completion: it resumes the persisted
   proposal, and only an absent record starts at 1;
2. the outstanding set is enumerated /before/ the rotation, so it is the set
   issued under the epoch being superseded rather than whatever survives it;
3. only then is the fence rotated. A permit minted under @from@ now fails
   'withPreparedGate''s equality check against the live epoch, so a delayed
   backend call from the dead run cannot land as though it were current.

An operation already at a settled or terminal phase is not a member: it holds no
authority to fence. The membership test is 'classifyRecordedPhase', so the set
here and the set the prepare gate would admit cannot drift apart.
-}
fenceOldPermits ::
    ProtectedSession session ->
    -- | plan digest
    Text ->
    IO (Either SessionError (OldPermitsFenced scope planId))
fenceOldPermits session planDigest = do
    settled <- establishInitialFence session planDigest 1
    case settled of
        Left failure -> pure (Left failure)
        Right (FenceEpoch from) -> do
            outstanding <- outstandingOperationKeys session planDigest
            case outstanding of
                Left failure -> pure (Left failure)
                Right keys -> do
                    rotated <- rotateFence session planDigest (FenceEpoch from :: FenceEpoch scope planId)
                    pure $ case rotated of
                        Left failure -> Left failure
                        Right (FenceEpoch to) -> Right (OldPermitsFenced planDigest from to keys)

{- | Every operation record of this plan whose recorded phase can still receive
effect authority, named by its own operation key.

This walks the store's own key space rather than any session's declared
membership: an operation whose session record was lost is still an outstanding
permit, and a fence set derived from membership would silently omit it.
-}
outstandingOperationKeys ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError [Text])
outstandingOperationKeys session planDigest = do
    enumerated <- enumerateOperationRecords session planDigest
    pure (fmap (sort . outstanding) enumerated)
  where
    outstanding records =
        [opKey | (disposition, opKey, _) <- records, holdsAuthority disposition]

    holdsAuthority disposition = case disposition of
        Settled -> False
        TerminalDisposition -> False
        _ -> True

{- | Every operation record of this plan, as
@(disposition, operationKey, sessionId)@ triples read out of the store's key
space.
-}
enumerateOperationRecords ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError [(OperationDisposition, Text, Text)])
enumerateOperationRecords session planDigest = do
    listed <- listProtectedRecords session
    case (listed, operationKeyNamespace planDigest) of
        (Left failure, _) -> pure (Left (SessionStoreFailure failure))
        (_, Left failure) -> pure (Left failure)
        (Right keys, Right namespace) ->
            foldM step (Right []) [raw | raw <- map recordKeyText keys, namespace `Text.isPrefixOf` raw]
      where
        step (Left failure) _ = pure (Left failure)
        step (Right acc) raw = do
            observed <- readOperationRecordAt session raw
            pure $ case observed of
                Left failure -> Left failure
                Right Nothing -> Right acc
                Right (Just (disposition, opKey, sid)) ->
                    Right ((disposition, opKey, sid) : acc)

{- | The @op.\<digest\>.@ prefix every one of this plan's operation records sits
under.
-}
operationKeyNamespace :: Text -> Either SessionError Text
operationKeyNamespace planDigest = do
    digest <- recordName planDigest
    pure ("op." <> digest <> ".")

{- | Read one operation record by its raw store key, recovering the session and
operation components from the key itself.

An operation key is @op.\<digest\>.\<session\>.\<operation\>@, so the two
components are the last two segments. A key that does not have them is not an
operation record this plan owns and is skipped rather than guessed at.
-}
readOperationRecordAt ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError (Maybe (OperationDisposition, Text, Text)))
readOperationRecordAt session raw = case splitOperationKey raw of
    Nothing -> pure (Right Nothing)
    Just (sid, opKey) -> case keyFor raw of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readTransactionRecord session key
            pure $ case observed of
                Left failure -> Left (transactionFailure failure)
                Right Nothing -> Right Nothing
                Right (Just record) ->
                    Right
                        ( Just
                            ( classifyRecordedPhase (phaseTextOf (transactionRecordPayload record))
                            , opKey
                            , sid
                            )
                        )

{- | Split @op.\<digest\>.\<session\>.\<operation\>@ into its session and
operation identities.

Both components come back through 'recordIdentity', so a namespaced record name
and the identity it denotes agree with what 'operationKeyFor' would have built.
-}
splitOperationKey :: Text -> Maybe (Text, Text)
splitOperationKey raw = case reverse (Text.splitOn "." raw) of
    (opKey : sid : _rest@(_ : _ : _)) -> Just (recordIdentity sid, recordIdentity opKey)
    _ -> Nothing

{- | One session as the manifest observed it, with the operation set the /store/
holds for it rather than the set the session record claims.
-}
data ManifestSession = ManifestSession
    { manifestSessionId :: SessionId
    , manifestSessionIsOpen :: Bool
    , manifestSessionOperations :: [Text]
    }
    deriving (Eq, Show)

{- | A manifest pairing the plan's independently enumerated complete session set
with its independently enumerated complete operation set.

"Independently" is the load-bearing word. The session set comes from the
@session.\<digest\>.@ key space and the operation set from the
@op.\<digest\>.@ key space; neither is derived from the other. The pairing is
then /checked/ rather than assumed, which is what makes a wrong membership a
refusal instead of an unnoticed divergence.

A zero-operation Open session is a required member (§ EE) — it is precisely what
a run killed immediately after 'openOperationSession' leaves behind, and a
manifest that dropped it would let the next admission believe the plan had no
outstanding session.
-}
data VerifiedSessionManifest scope planId
    = VerifiedSessionManifest Text [ManifestSession]

instance Show (VerifiedSessionManifest scope planId) where
    show (VerifiedSessionManifest plan sessions) =
        "VerifiedSessionManifest " <> show plan <> " " <> show (length sessions)

-- | The plan digest this manifest was taken over.
manifestPlanDigest :: VerifiedSessionManifest scope planId -> Text
manifestPlanDigest (VerifiedSessionManifest plan _) = plan

-- | Every session of the plan, in sorted identity order.
manifestSessions :: VerifiedSessionManifest scope planId -> [ManifestSession]
manifestSessions (VerifiedSessionManifest _ sessions) = sessions

-- | How many operations the paired complete operation set holds.
manifestOperationCount :: VerifiedSessionManifest scope planId -> Int
manifestOperationCount = sum . map (length . manifestSessionOperations) . manifestSessions

{- | Verify the manifest, refusing every way the two sets can fail to pair.

The refusals are exactly § EE's: a missing record, a duplicate record, and a
wrong membership. Concretely:

* an operation record naming a session with no session record is
  'SessionManifestOrphanOperation' — the operation exists but nothing owns it,
  so no admission may be minted over it;
* two store keys resolving to one session identity is
  'SessionManifestDuplicateSession'. Record names are namespaced, so this needs
  two differently-spelled keys denoting the same identity; it is checked rather
  than assumed impossible because the pairing's correctness rests on the session
  set being a set;
* a session whose record declares a membership different from the operation
  records the store actually holds is 'SessionManifestMembershipMismatch'. The
  enumerated set wins as the truth and the declared one is reported beside it,
  because the declaration is what a killed writer can leave stale.

A session record that predates exact membership declares none; that is not a
mismatch, and its enumerated operations are simply adopted.
-}
verifySessionManifest ::
    ProtectedSession session ->
    -- | plan digest
    Text ->
    IO (Either SessionError (VerifiedSessionManifest scope planId))
verifySessionManifest session planDigest = do
    coordinator <- ensureCoordinator session planDigest
    case coordinator of
        Left failure -> pure (Left failure)
        Right _ -> do
            listed <- listProtectedRecords session
            case (listed, sessionKeyPrefixFor planDigest) of
                (Left failure, _) -> pure (Left (SessionStoreFailure failure))
                (_, Left failure) -> pure (Left failure)
                (Right keys, Right prefix) -> do
                    let identities =
                            [ recordIdentity (Text.drop (Text.length prefix) raw)
                            | raw <- map recordKeyText keys
                            , prefix `Text.isPrefixOf` raw
                            ]
                    case firstDuplicate (sort identities) of
                        Just repeated ->
                            pure (Left (SessionManifestDuplicateSession (SessionId repeated)))
                        Nothing -> do
                            enumerated <- enumerateOperationRecords session planDigest
                            case enumerated of
                                Left failure -> pure (Left failure)
                                Right records ->
                                    pairEnumeratedSets session planDigest (sort identities) records

{- | Pair the enumerated session set with the enumerated operation set, or refuse.

An operation whose owning session has no record is refused first: it is the one
failure that cannot be repaired by reading further, because there is no session
whose membership could be compared against it.
-}
pairEnumeratedSets ::
    ProtectedSession session ->
    Text ->
    [Text] ->
    [(OperationDisposition, Text, Text)] ->
    IO (Either SessionError (VerifiedSessionManifest scope planId))
pairEnumeratedSets session planDigest identities records =
    case [(opKey, sid) | (_, opKey, sid) <- records, sid `notElem` identities] of
        ((opKey, sid) : _) -> pure (Left (SessionManifestOrphanOperation opKey sid))
        [] -> do
            members <- foldM step (Right []) identities
            pure (fmap (VerifiedSessionManifest planDigest . reverse) members)
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) sid = do
        observed <- readSessionRecord session planDigest (SessionId sid)
        pure $ case observed of
            Left failure -> Left failure
            Right Nothing -> Left (SessionManifestMissingRecord (SessionId sid))
            Right (Just (_, state))
                | sessionRecordHasExactMembership state
                , sort (sessionRecordMembers state) /= enumeratedFor sid ->
                    Left
                        ( SessionManifestMembershipMismatch
                            (SessionId sid)
                            (Text.intercalate "," (sort (sessionRecordMembers state)))
                            (Text.intercalate "," (enumeratedFor sid))
                        )
                | otherwise ->
                    Right
                        ( ManifestSession
                            { manifestSessionId = SessionId sid
                            , manifestSessionIsOpen = sessionRecordIsOpen state
                            , manifestSessionOperations = enumeratedFor sid
                            }
                            : acc
                        )

    enumeratedFor sid = sort [opKey | (_, opKey, owner) <- records, owner == sid]

-- | The first value that appears twice in a sorted list.
firstDuplicate :: (Eq a) => [a] -> Maybe a
firstDuplicate (x : y : rest)
    | x == y = Just x
    | otherwise = firstDuplicate (y : rest)
firstDuplicate _ = Nothing

{- | What the interpreter did with one recorded operation.

Every constructor is a /handled/ outcome. The unknown phase is not one of them:
it has no disposition the interpreter may act on, so it refuses the whole
interpretation rather than appearing here as a fifth kind of success.
-}
data RecoveredOperation
    = -- | already committed; left exactly as it was
      OperationAlreadySettled Text Text
    | -- | already terminal; left exactly as it was
      OperationAlreadyTerminal Text Text
    | -- | pre-call, so no effect was attempted; recorded terminal for this run
      OperationAbandonedPreCall Text Text
    | -- | observed-absent under the old fence; recorded terminal for this run
      OperationAbandonedRetryable Text Text
    deriving (Eq, Show)

{- | The result of running the recorded-session interpreter over one plan.

Its constructor is private: it exists only as evidence that every session in the
manifest was driven to Closed and every one of their operations was handled.
-}
data InterpretedRecovery scope planId
    = InterpretedRecovery Text [SessionId] [RecoveredOperation]

instance Show (InterpretedRecovery scope planId) where
    show (InterpretedRecovery plan sessions operations) =
        "InterpretedRecovery "
            <> show plan
            <> " "
            <> show (length sessions)
            <> " "
            <> show (length operations)

interpretedRecoveryPlanDigest :: InterpretedRecovery scope planId -> Text
interpretedRecoveryPlanDigest (InterpretedRecovery plan _ _) = plan

-- | Every session the interpretation drove to Closed, in the order it drove them.
interpretedRecoverySessions :: InterpretedRecovery scope planId -> [SessionId]
interpretedRecoverySessions (InterpretedRecovery _ sessions _) = sessions

-- | Every operation the interpretation handled, with what it did to each.
interpretedRecoveryOperations :: InterpretedRecovery scope planId -> [RecoveredOperation]
interpretedRecoveryOperations (InterpretedRecovery _ _ operations) = operations

{- | Drive every session in the manifest to Closed under the fresh broker
generation, handling each of its operations by its recorded disposition.

This is § EE's recorded-session interpreter, and it is what normal activation
with an older Open session must run before any current-broker session admission.
It is a strictly stronger thing than 'recoverAbandonedSessions': that sweep
closes Open sessions and /counts/ continuable operations, leaving them at a phase
a later holder could still prepare against, and it never rebinds a session to the
generation that is about to run. This one settles them and rebinds.

Per session, in order:

1. every operation is classified. 'UnknownDisposition' refuses the whole
   interpretation — a phase this binary cannot classify is exactly the case where
   guessing is unsafe, so it blocks admission rather than being swept;
2. a 'Continuable' or 'FencedRetryable' operation is recorded terminal at
   @RecoveryAbandoned@. That is sound in both cases and for the same reason: the
   run that registered the operation is dead, so nothing will continue it. The
   pre-call one attempted no effect at all; the retryable one attempted an effect
   and observed its absence, and its permit is in the set 'fenceOldPermits'
   already superseded, so a delayed landing cannot be mistaken for this run's;
3. a 'Settled' or 'TerminalDisposition' operation is left byte-for-byte alone.
   Recovery never rewrites committed work;
4. the session record is compare-and-swapped to the fresh broker generation while
   /still Open/ — the rebind § EE names — so what closes next is unambiguously
   this generation's record and not a record another generation could still be
   holding a version of;
5. only then is the session closed, which re-proves through
   'closeOperationSession' that no operation was left unsettled.

The permit is threaded through all of it, so the whole interpretation is one
chain of sole-successor advances rather than a set of independent writes.
-}
interpretRecordedSessions ::
    ProtectedSession session ->
    BrokerEpoch brokerGeneration ->
    VerifiedSessionManifest scope planId ->
    OldPermitsFenced scope planId ->
    ProjectPermit scope planId ->
    IO (Either SessionError (InterpretedRecovery scope planId, ProjectPermit scope planId))
interpretRecordedSessions session epoch manifest fenced permit
    | manifestPlanDigest manifest /= oldPermitsFencedPlanDigest fenced =
        pure
            ( Left
                ( SessionRecoveryPlanMismatch
                    (manifestPlanDigest manifest)
                    (oldPermitsFencedPlanDigest fenced)
                )
            )
    | otherwise = do
        driven <- foldM step (Right ([], [], permit)) (manifestSessions manifest)
        pure $ case driven of
            Left failure -> Left failure
            Right (sessions, operations, finalPermit) ->
                Right
                    ( InterpretedRecovery planDigest (reverse sessions) (reverse operations)
                    , finalPermit
                    )
  where
    planDigest = manifestPlanDigest manifest

    step (Left failure) _ = pure (Left failure)
    step (Right (sessions, operations, current)) member = do
        handled <- foldM (handleOperation member) (Right (operations, current)) (manifestSessionOperations member)
        case handled of
            Left failure -> pure (Left failure)
            Right (afterOperations, afterPermit) -> do
                closed <- rebindAndClose member afterPermit
                pure $ case closed of
                    Left failure -> Left failure
                    Right nextPermit ->
                        Right (manifestSessionId member : sessions, afterOperations, nextPermit)

    handleOperation _ (Left failure) _ = pure (Left failure)
    handleOperation member (Right (operations, current)) opKey =
        case operationKeyFor planDigest (manifestSessionId member) opKey of
            Left failure -> pure (Left failure)
            Right oKey -> do
                observed <- readTransactionRecord session oKey
                case observed of
                    Left failure -> pure (Left (transactionFailure failure))
                    -- The manifest enumerated this key from the store under the
                    -- same protected entry, so an absent record here is a torn
                    -- store rather than an ordinary miss.
                    Right Nothing -> pure (Left (SessionManifestOrphanOperation opKey (sessionIdText (manifestSessionId member))))
                    Right (Just record) -> do
                        let recorded = phaseTextOf (transactionRecordPayload record)
                        case classifyRecordedPhase recorded of
                            UnknownDisposition ->
                                pure (Left (SessionUnclassifiedPhase opKey recorded))
                            Settled ->
                                pure (Right (OperationAlreadySettled opKey recorded : operations, current))
                            TerminalDisposition ->
                                pure (Right (OperationAlreadyTerminal opKey recorded : operations, current))
                            Continuable ->
                                abandon member oKey record opKey recorded operations current OperationAbandonedPreCall
                            FencedRetryable ->
                                abandon member oKey record opKey recorded operations current OperationAbandonedRetryable

    abandon member oKey record opKey recorded operations (ProjectPermit current) build = do
        let desired =
                encodeFields
                    [ "RecoveryAbandoned"
                    , sessionIdText (manifestSessionId member)
                    , Text.pack (show (oldPermitsFencedTo fenced))
                    , Text.pack (show (recordedAttempt (transactionRecordPayload record)))
                    ]
        advanced <-
            runTransaction
                session
                planDigest
                current
                TxnAcknowledgeOutcome
                [operationTransactionTarget oKey (Just record) desired]
        pure $ case advanced of
            Left failure -> Left failure
            Right next -> Right (build opKey recorded : operations, ProjectPermit next)

    rebindAndClose member current@(ProjectPermit raw) =
        case sessionKey planDigest (manifestSessionId member) of
            Left failure -> pure (Left failure)
            Right sKey -> do
                observed <- readSessionRecord session planDigest (manifestSessionId member)
                case observed of
                    Left failure -> pure (Left failure)
                    Right Nothing ->
                        pure (Left (SessionManifestMissingRecord (manifestSessionId member)))
                    Right (Just (record, state))
                        -- A session already Closed needs neither rebind nor
                        -- close; it is a member of the manifest because the set
                        -- is complete, not because it has work outstanding.
                        | not (sessionRecordIsOpen state) -> pure (Right current)
                        | otherwise -> do
                            rebound <-
                                runTransaction
                                    session
                                    planDigest
                                    raw
                                    TxnRebindSession
                                    [ sessionTransactionTarget
                                        sKey
                                        (Just record)
                                        ( encodeSessionRecord
                                            True
                                            (Text.pack (show (brokerEpochWord epoch)))
                                            (manifestSessionOperations member)
                                        )
                                    ]
                            case rebound of
                                Left failure -> pure (Left failure)
                                Right next ->
                                    closeOperationSession
                                        session
                                        OperationSession
                                            { sessionRecordId = manifestSessionId member
                                            , sessionPlanDigest = planDigest
                                            , sessionBrokerGeneration = brokerEpochWord epoch
                                            }
                                        (ProjectPermit next)

{- | Proof that the current broker generation may open sessions for this plan.

§ EE: "Only both complete session/operation sets yield
'CurrentBrokerSessionAdmission'; missing/duplicate records, wrong membership,
missing/replaced resource evidence, or unresolved recovery cannot manufacture it
or create a second logical session."

So its constructor is private and 'admitCurrentBroker' is its sole producer,
requiring all three of the fence set, the manifest, and the interpretation that
consumed them — and requiring the interpretation to have covered the manifest
exactly. A caller cannot verify a manifest, skip the interpreter, and present the
manifest alone.
-}
data CurrentBrokerSessionAdmission scope planId brokerGeneration
    = CurrentBrokerSessionAdmission Text Word64 Int Int

instance Show (CurrentBrokerSessionAdmission scope planId brokerGeneration) where
    show (CurrentBrokerSessionAdmission plan generation sessions operations) =
        "CurrentBrokerSessionAdmission "
            <> show plan
            <> " "
            <> show generation
            <> " "
            <> show sessions
            <> " "
            <> show operations

admissionPlanDigest :: CurrentBrokerSessionAdmission scope planId brokerGeneration -> Text
admissionPlanDigest (CurrentBrokerSessionAdmission plan _ _ _) = plan

admissionBrokerGeneration ::
    CurrentBrokerSessionAdmission scope planId brokerGeneration -> Word64
admissionBrokerGeneration (CurrentBrokerSessionAdmission _ generation _ _) = generation

-- | How many sessions the admission's manifest covered.
admissionSessionCount :: CurrentBrokerSessionAdmission scope planId brokerGeneration -> Int
admissionSessionCount (CurrentBrokerSessionAdmission _ _ sessions _) = sessions

-- | How many operations the admission's manifest covered.
admissionOperationCount :: CurrentBrokerSessionAdmission scope planId brokerGeneration -> Int
admissionOperationCount (CurrentBrokerSessionAdmission _ _ _ operations) = operations

{- | Mint current-broker session admission from the complete evidence, or refuse.

Every input is compared rather than trusted:

* all three values must be over the same plan digest, because the phantom indices
  alone would let evidence taken for one plan authorize another;
* the interpretation must have covered exactly the manifest's sessions. A
  manifest of three sessions and an interpretation of two is
  'SessionRecoveryIncomplete', which is the "unresolved recovery" § EE says
  cannot manufacture an admission;
* every session must be observed Closed /again/, at this store version, through
  'verifyAllSessionsClosed'. The interpreter proved it drove them closed; this
  re-proves it against the store after the fact, so a session reopened between
  the interpretation and the admission refuses.
-}
admitCurrentBroker ::
    ProtectedSession session ->
    BrokerEpoch brokerGeneration ->
    VerifiedSessionManifest scope planId ->
    OldPermitsFenced scope planId ->
    InterpretedRecovery scope planId ->
    IO (Either SessionError (CurrentBrokerSessionAdmission scope planId brokerGeneration))
admitCurrentBroker session epoch manifest fenced interpreted
    | manifestPlanDigest manifest /= oldPermitsFencedPlanDigest fenced =
        pure
            ( Left
                ( SessionRecoveryPlanMismatch
                    (manifestPlanDigest manifest)
                    (oldPermitsFencedPlanDigest fenced)
                )
            )
    | manifestPlanDigest manifest /= interpretedRecoveryPlanDigest interpreted =
        pure
            ( Left
                ( SessionRecoveryPlanMismatch
                    (manifestPlanDigest manifest)
                    (interpretedRecoveryPlanDigest interpreted)
                )
            )
    | sort (map manifestSessionId (manifestSessions manifest))
        /= sort (interpretedRecoverySessions interpreted) =
        pure
            ( Left
                ( SessionRecoveryIncomplete
                    (length (manifestSessions manifest))
                    (length (interpretedRecoverySessions interpreted))
                )
            )
    | otherwise = do
        closed <- verifyAllSessionsClosed session (manifestPlanDigest manifest)
        pure $ case closed of
            Left (SessionStillOpen sid) ->
                Left (SessionRecoveryUnresolved (sessionIdText sid <> " is still open"))
            Left failure -> Left failure
            Right (proof :: VerifiedAllSessionsClosed scope planId) ->
                Right
                    ( CurrentBrokerSessionAdmission
                        (allSessionsClosedPlanDigest proof)
                        (brokerEpochWord epoch)
                        (length (manifestSessions manifest))
                        (manifestOperationCount manifest)
                    )

-- ---------------------------------------------------------------------------
-- The prepare compare-and-swap

{- | Run one operation's prepare compare-and-swap.

The order is the contract. Before the continuation sees anything, this
revalidates the live broker generation, that the session is still Open, that the
project journal is Open and at the presented version, that the fence is the
current observed one, and that the operation's recorded phase is one recovery
classified as able to receive authority. It then **durably records the
operation-specific unknown phase**, so a crash between here and the adapter
leaves evidence that an effect may have been attempted. Only then does it mint
the pure prepared pair and hand both halves to the continuation.

The journal version it consumed is spent: the successor permit carries the new
version, and a retained older permit fails the compare-and-swap.
-}
withPreparedGate ::
    ProtectedSession session ->
    OperationSession scope planId ->
    BrokerEpoch brokerGeneration ->
    FenceEpoch scope planId ->
    -- | the operation key
    Text ->
    -- | the unknown phase to record before the call
    Text ->
    ProjectPermit scope planId ->
    ( PreparedGate ->
      ProjectPermit scope planId ->
      IO (Either SessionError result)
    ) ->
    IO (Either SessionError result)
withPreparedGate session sess epoch fence opKey unknownPhase (ProjectPermit presented) use
    | brokerEpochWord epoch /= sessionBrokerGeneration sess =
        pure
            ( Left
                ( SessionBrokerEpochMismatch
                    (sessionBrokerGeneration sess)
                    (brokerEpochWord epoch)
                )
            )
    | otherwise = withCurrentOpenPermit session plan presented $ do
        live <- readSessionRecord session plan (sessionRecordId sess)
        case live of
            Left failure -> pure (Left failure)
            Right Nothing -> pure (Left (SessionNotOpen (sessionRecordId sess)))
            Right (Just (_, state))
                | not (sessionRecordIsOpen state) ->
                    pure (Left (SessionNotOpen (sessionRecordId sess)))
                | otherwise -> do
                    members <- sessionOperationNames session plan (sessionRecordId sess) state
                    case members of
                        Left failure -> pure (Left failure)
                        Right names
                            | opKey `notElem` names ->
                                pure (Left (SessionOperationUnregistered opKey))
                            | otherwise -> do
                                observedFence <- currentFence session plan
                                case observedFence of
                                    Left failure -> pure (Left failure)
                                    Right (FenceEpoch liveEpoch)
                                        | liveEpoch /= fenceEpochWord fence ->
                                            pure (Left (SessionFenceSuperseded (fenceEpochWord fence) liveEpoch))
                                        | otherwise -> gateOperation liveEpoch
  where
    plan = sessionPlanDigest sess

    gateOperation liveEpoch = case operationKeyFor plan (sessionRecordId sess) opKey of
        Left failure -> pure (Left failure)
        Right oKey -> do
            observed <- readTransactionRecord session oKey
            case observed of
                Left failure -> pure (Left (transactionFailure failure))
                Right Nothing -> pure (Left (SessionOperationUnregistered opKey))
                Right (Just record) -> do
                    let recorded = phaseTextOf (transactionRecordPayload record)
                        priorFence = recordedFenceOf (transactionRecordPayload record)
                    case classifyRecordedPhase recorded of
                        UnknownDisposition -> pure (Left (SessionUnclassifiedPhase opKey recorded))
                        Settled -> pure (Left (SessionOperationSettled opKey recorded))
                        TerminalDisposition -> pure (Left (SessionOperationTerminal opKey recorded))
                        FencedRetryable
                            | priorFence >= liveEpoch ->
                                pure (Left (SessionRetryNeedsFreshFence opKey priorFence liveEpoch))
                            | otherwise -> advance oKey record liveEpoch
                        Continuable -> advance oKey record liveEpoch

    advance oKey record liveEpoch = do
        let attempt = recordedAttempt (transactionRecordPayload record) + 1
            desired =
                encodeFields
                    [ unknownPhase
                    , sessionIdText (sessionRecordId sess)
                    , Text.pack (show liveEpoch)
                    , Text.pack (show attempt)
                    ]
        advanced <-
            runTransaction
                session
                plan
                presented
                TxnPrepareOperation
                [operationTransactionTarget oKey (Just record) desired]
        case advanced of
            Left failure -> pure (Left failure)
            Right next -> do
                committed <- readTransactionRecord session oKey
                case committed of
                    Left failure -> pure (Left (transactionFailure failure))
                    Right Nothing -> pure (Left (SessionOperationUnregistered opKey))
                    Right (Just durable)
                        | transactionRecordPayload durable /= desired ->
                            pure (Left (SessionRecordCorrupt "prepared operation"))
                        | otherwise ->
                            use
                                ( mintPreparedGate
                                    plan
                                    opKey
                                    (sessionIdText (sessionRecordId sess))
                                    liveEpoch
                                    attempt
                                    (recordVersionWord (transactionRecordVersion durable))
                                )
                                (ProjectPermit next)

{- | The route from a step's plan-minted execution descriptor to the prepared
gate for **that step's own operation** (§ CC).

'withPreparedGate' takes the operation key as an ordinary argument, which is
correct for the core's own operations but is not a route a *step action* may
take: an action holding a descriptor could name any key the plan happens to
contain, and prepare a node other than its own. This seam removes the choice.
The plan digest and the operation key are both read off the descriptor, whose
sole producer is 'HostBootstrap.Reconcile.stepExecutionFor' over a real
validated plan, so a step can reach exactly one gate — its own.

The @scope@ and @planId@ indices are shared with the 'OperationSession' and the
'FenceEpoch', so a descriptor from one plan cannot be presented in another
plan's session. The plan digest is compared as a *value* as well, because those
indices are phantom on the session side and a caller could otherwise instantiate
them to agree: the descriptor's digest comes from the plan and the session's from
the journal, and a disagreement means the two are not the same interpretation.

Everything else — the broker epoch, the open session, the operation's
registration, the live fence, the recorded phase, and the durable unknown write —
is 'withPreparedGate''s own compare-and-swap, unchanged.
-}
withStepPreparedGate ::
    ProtectedSession session ->
    OperationSession scope planId ->
    BrokerEpoch brokerGeneration ->
    FenceEpoch scope planId ->
    StepExecution scope planId ->
    -- | the unknown phase to record before the call
    Text ->
    ProjectPermit scope planId ->
    ( PreparedGate ->
      ProjectPermit scope planId ->
      IO (Either SessionError result)
    ) ->
    IO (Either SessionError result)
withStepPreparedGate session sess epoch fence execution unknownPhase permit use
    | stepExecutionPlanDigest execution /= sessionPlanDigest sess =
        pure
            ( Left
                ( SessionStepPlanMismatch
                    (sessionPlanDigest sess)
                    (stepExecutionPlanDigest execution)
                )
            )
    | otherwise =
        withPreparedGate
            session
            sess
            epoch
            fence
            (stepExecutionOperationKey execution)
            unknownPhase
            permit
            use

recordedAttempt :: ByteString -> Word64
recordedAttempt raw = case decodeFields raw of
    (_ : _ : _ : attempt : _) -> maybe 0 id (readWord attempt)
    _ -> 0

-- ---------------------------------------------------------------------------
-- Terminal acknowledgment

{- | A settled terminal observation. Its eliminator is the only way to read the
adapter's result, and it yields that result together with the sole successor
permit — so a caller cannot take the result and keep the old permit.
-}
data OperationAdvance scope planId result
    = OperationAdvance result (ProjectPermit scope planId)

instance Show (OperationAdvance scope planId result) where
    show (OperationAdvance _ permit) = "OperationAdvance <result> " <> show permit

{- | Record an operation's terminal phase and mint its advance.

Refuses a phase the journal graph does not allow from the recorded one, so an
adapter cannot report an outcome that skips the durable unknown state.
-}
acknowledgeOutcome ::
    ProtectedSession session ->
    OperationSession scope planId ->
    PreparedGate ->
    -- | the observed terminal phase
    Text ->
    result ->
    ProjectPermit scope planId ->
    IO (Either SessionError (OperationAdvance scope planId result))
acknowledgeOutcome session sess gate observedPhase result (ProjectPermit presented)
    | preparedGatePlan gate /= plan =
        pure (Left (SessionPreparedGateMismatch "plan"))
    | preparedGateSession gate /= sessionIdText (sessionRecordId sess) =
        pure (Left (SessionPreparedGateMismatch "session"))
    | otherwise =
        withCurrentOpenPermit session plan presented $
            case operationKeyFor plan (sessionRecordId sess) (preparedGateOperation gate) of
                Left failure -> pure (Left failure)
                Right oKey -> do
                    observed <- readTransactionRecord session oKey
                    case observed of
                        Left failure -> pure (Left (transactionFailure failure))
                        Right Nothing -> pure (Left (SessionOperationUnregistered (preparedGateOperation gate)))
                        Right (Just record)
                            | transactionVersionOf record /= preparedGateJournalVersion gate ->
                                pure
                                    ( Left
                                        ( SessionStaleJournalVersion
                                            (preparedGateJournalVersion gate)
                                            (transactionVersionOf record)
                                        )
                                    )
                            | not (gateMatchesRecord sess gate (transactionRecordPayload record)) ->
                                pure (Left (SessionPreparedGateMismatch "durable operation"))
                            | otherwise -> do
                                advanced <-
                                    runTransaction
                                        session
                                        plan
                                        presented
                                        TxnAcknowledgeOutcome
                                        [ operationTransactionTarget
                                            oKey
                                            (Just record)
                                            ( encodeFields
                                                [ observedPhase
                                                , sessionIdText (sessionRecordId sess)
                                                , Text.pack (show (preparedGateFence gate))
                                                , Text.pack (show (preparedGateAttempt gate))
                                                ]
                                            )
                                        ]
                                pure
                                    ( OperationAdvance result . ProjectPermit
                                        <$> advanced
                                    )
  where
    plan = sessionPlanDigest sess

transactionVersionOf :: TransactionRecord -> Word64
transactionVersionOf = recordVersionWord . transactionRecordVersion

gateMatchesRecord :: OperationSession scope planId -> PreparedGate -> ByteString -> Bool
gateMatchesRecord sess gate raw = case decodeFields raw of
    [_phase, recordedSession, fence, attempt] ->
        recordedSession == sessionIdText (sessionRecordId sess)
            && readWord fence == Just (preparedGateFence gate)
            && readWord attempt == Just (preparedGateAttempt gate)
    _ -> False

-- | Eliminate an advance: the result is available only with its successor permit.
withOperationAdvance ::
    OperationAdvance scope planId result ->
    (result -> ProjectPermit scope planId -> outcome) ->
    outcome
withOperationAdvance (OperationAdvance result permit) use = use result permit

-- ---------------------------------------------------------------------------
-- Failures

data SessionError
    = SessionStoreFailure ProtectedError
    | SessionTransactionFailure Text
    | SessionRecordCorrupt Text
    | SessionProjectMissing Text
    | SessionProjectClosed Text
    | -- | terminal close is under way, so no new work is admitted
      SessionProjectClosing Text
    | -- | a session was still Open when a completeness proof was required
      SessionStillOpen SessionId
    | SessionStaleProjectPermit Word64
    | SessionOlderStillOpen SessionId
    | SessionUnknown SessionId
    | SessionNotOpen SessionId
    | SessionBrokerEpochMismatch Word64 Word64
    | SessionFenceInvalid Text
    | SessionFenceMissing Text
    | SessionFenceUnsettled FencePhase
    | -- | presented epoch, then the live one
      SessionFenceSuperseded Word64 Word64
    | SessionIntentAlreadyRecorded Text Text
    | SessionIntentOriginRefused Text Text
    | SessionOperationUnregistered Text
    | SessionOperationSettled Text Text
    | SessionOperationTerminal Text Text
    | SessionOperationUnsettled Text
    | SessionRetryNeedsFreshFence Text Word64 Word64
    | SessionUnclassifiedPhase Text Text
    | SessionPreparedGateMismatch Text
    | -- | the session's plan digest, then the step descriptor's
      SessionStepPlanMismatch Text Text
    | -- | consumed version, then the version actually on the record
      SessionStaleJournalVersion Word64 Word64
    | -- | an operation record names a session the manifest does not carry
      SessionManifestOrphanOperation Text Text
    | -- | the store holds two records resolving to one session identity
      SessionManifestDuplicateSession SessionId
    | -- | the session's declared membership, then what the store actually holds
      SessionManifestMembershipMismatch SessionId Text Text
    | -- | a manifest member's session record vanished between enumeration and use
      SessionManifestMissingRecord SessionId
    | -- | a value taken over one plan digest was presented for another
      SessionRecoveryPlanMismatch Text Text
    | -- | recovery left something an operator must resolve, so nothing is admitted
      SessionRecoveryUnresolved Text
    | -- | the interpretation did not cover the manifest it was taken against
      SessionRecoveryIncomplete Int Int
    deriving (Eq, Show)

sessionErrorMessage :: SessionError -> String
sessionErrorMessage err = case err of
    SessionStoreFailure failure -> "session: " <> Text.unpack (protectedErrorMessage failure)
    SessionTransactionFailure failure -> "session: " <> Text.unpack failure
    SessionRecordCorrupt what -> "session: the " <> Text.unpack what <> " record is unreadable"
    SessionProjectMissing plan -> "session: no project journal for plan " <> Text.unpack plan
    SessionProjectClosed plan -> "session: the project journal for " <> Text.unpack plan <> " is closed"
    SessionProjectClosing plan ->
        "session: the project journal for "
            <> Text.unpack plan
            <> " is closing; no new work is admitted"
    SessionStillOpen sid ->
        "session: " <> Text.unpack (sessionIdText sid) <> " is still open"
    SessionStaleProjectPermit version ->
        "session: project permit version " <> show version <> " is no longer current"
    SessionOlderStillOpen sid ->
        "session: an older session " <> Text.unpack (sessionIdText sid) <> " is still open"
    SessionUnknown sid -> "session: no record for " <> Text.unpack (sessionIdText sid)
    SessionNotOpen sid -> "session: " <> Text.unpack (sessionIdText sid) <> " is not open"
    SessionBrokerEpochMismatch expected actual ->
        "session: broker generation " <> show actual <> " does not match the session's " <> show expected
    SessionFenceInvalid detail -> "session: " <> Text.unpack detail
    SessionFenceMissing plan -> "session: no fence for plan " <> Text.unpack plan
    SessionFenceUnsettled phase -> "session: the fence is still at " <> show phase
    SessionFenceSuperseded presented live ->
        "session: fence epoch " <> show presented <> " was superseded by " <> show live
    SessionIntentAlreadyRecorded opKey phase ->
        "session: operation " <> Text.unpack opKey <> " already has a record at " <> Text.unpack phase
    SessionIntentOriginRefused opKey phase ->
        "session: operation " <> Text.unpack opKey <> " cannot reacquire from " <> Text.unpack phase
    SessionOperationUnregistered opKey ->
        "session: operation " <> Text.unpack opKey <> " has no registered intent"
    SessionOperationSettled opKey phase ->
        "session: operation " <> Text.unpack opKey <> " is settled at " <> Text.unpack phase
    SessionOperationTerminal opKey phase ->
        "session: operation " <> Text.unpack opKey <> " is terminal at " <> Text.unpack phase
    SessionOperationUnsettled opKey ->
        "session: operation " <> Text.unpack opKey <> " has not settled"
    SessionRetryNeedsFreshFence opKey recorded live ->
        "session: operation "
            <> Text.unpack opKey
            <> " was observed at fence "
            <> show recorded
            <> " and needs a fence above "
            <> show live
    SessionUnclassifiedPhase opKey phase ->
        "session: operation " <> Text.unpack opKey <> " is at unrecognised phase " <> Text.unpack phase
    SessionPreparedGateMismatch field ->
        "session: the prepared gate does not match the " <> Text.unpack field
    SessionStepPlanMismatch sessionPlan stepPlan ->
        "session: the step descriptor belongs to plan "
            <> Text.unpack stepPlan
            <> ", but this session is open on "
            <> Text.unpack sessionPlan
    SessionStaleJournalVersion consumed actual ->
        "session: journal version " <> show consumed <> " was superseded by " <> show actual
    SessionManifestOrphanOperation opKey sid ->
        "session: operation "
            <> Text.unpack opKey
            <> " names session "
            <> Text.unpack sid
            <> ", which is not a member of the manifest"
    SessionManifestDuplicateSession sid ->
        "session: " <> Text.unpack (sessionIdText sid) <> " is recorded more than once"
    SessionManifestMembershipMismatch sid declared enumerated ->
        "session: "
            <> Text.unpack (sessionIdText sid)
            <> " declares membership ["
            <> Text.unpack declared
            <> "] but the store holds ["
            <> Text.unpack enumerated
            <> "]"
    SessionManifestMissingRecord sid ->
        "session: the record for " <> Text.unpack (sessionIdText sid) <> " is gone"
    SessionRecoveryPlanMismatch expected presented ->
        "session: recovery evidence for plan "
            <> Text.unpack presented
            <> " was presented for "
            <> Text.unpack expected
    SessionRecoveryUnresolved detail ->
        "session: recovery is unresolved: " <> Text.unpack detail
    SessionRecoveryIncomplete manifested interpreted ->
        "session: the interpretation covered "
            <> show interpreted
            <> " of the manifest's "
            <> show manifested
            <> " sessions"
