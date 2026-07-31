{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The protected operation session, fence rotation, and the prepare
compare-and-swap (§ EE, Sprint 15.9).

Sprint 9.10 landed the *pure* journal algebra in "HostBootstrap.Reconcile":
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
import HostBootstrap.Lifecycle.Prepared (
    PreparedGate,
    decodeFields,
    encodeFields,
    preparedGateAttempt,
    preparedGateFence,
    preparedGateJournalVersion,
    preparedGateOperation,
    preparedGatePlan,
    recordDurableUnknown,
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
    protectedErrorMessage,
    readProtectedRecord,
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

{- | The sole successor permit for one project-journal version.

Every operation that advances the journal returns exactly one of these, and the
version inside it is the version the *next* operation must present. A retained
older permit therefore cannot authorize a second advance — the compare-and-swap
against its version fails.
-}
newtype ProjectPermit scope planId = ProjectPermit RecordVersion

instance Show (ProjectPermit scope planId) where
    show (ProjectPermit version) = "ProjectPermit " <> show (recordVersionWord version)

-- | The journal version this permit authorizes the next transition against.
projectPermitVersion :: ProjectPermit scope planId -> Word64
projectPermitVersion (ProjectPermit version) = recordVersionWord version

projectKey :: Text -> Either SessionError RecordKey
projectKey planDigest = keyFor ("project." <> planDigest)

keyFor :: Text -> Either SessionError RecordKey
keyFor raw = either (Left . SessionStoreFailure) Right (mkRecordKey raw)

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
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (Left (SessionStoreFailure failure))
                Right (Just record) -> case decodeJournalState (protectedRecordBytes record) of
                    Just OpenProject -> pure (Right (ProjectPermit (protectedRecordVersion record)))
                    -- A closing or closed project accepts no new work: the
                    -- distinction matters to recovery, not to this opener.
                    Just (ClosingProject _) -> pure (Left (SessionProjectClosing planDigest))
                    Just ClosedProject -> pure (Left (SessionProjectClosed planDigest))
                    Nothing -> pure (Left (SessionRecordCorrupt "project journal"))
                Right Nothing -> do
                    written <-
                        compareAndSwapProtectedRecord session key ExpectAbsent (encodeFields ["open"])
                    pure $ case written of
                        Left failure -> Left (SessionStoreFailure failure)
                        Right version -> Right (ProjectPermit version)

-- | Read the journal state without advancing it.
readProjectJournalState ::
    ProtectedSession session ->
    Text ->
    IO (Either SessionError ProjectJournalState)
readProjectJournalState session planDigest =
    case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord session key
            pure $ case observed of
                Left failure -> Left (SessionStoreFailure failure)
                Right Nothing -> Left (SessionProjectMissing planDigest)
                Right (Just record) ->
                    maybe
                        (Left (SessionRecordCorrupt "project journal"))
                        Right
                        (decodeJournalState (protectedRecordBytes record))

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
    IO (Either SessionError (ProjectPermit scope planId))
beginClosingProject session planDigest epoch (ProjectPermit permitVersion)
    | epoch == 0 = pure (Left (SessionRecordCorrupt "closing epoch must be positive"))
    | otherwise = case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (Left (SessionStoreFailure failure))
                Right Nothing -> pure (Left (SessionProjectMissing planDigest))
                Right (Just record) -> case decodeJournalState (protectedRecordBytes record) of
                    Nothing -> pure (Left (SessionRecordCorrupt "project journal"))
                    Just ClosedProject -> pure (Left (SessionProjectClosed planDigest))
                    -- Resuming the same persisted Closing epoch is idempotent;
                    -- a different one is a second close and is refused.
                    Just (ClosingProject persisted)
                        | persisted == epoch ->
                            pure (Right (ProjectPermit (protectedRecordVersion record)))
                        | otherwise -> pure (Left (SessionProjectClosing planDigest))
                    Just OpenProject -> do
                        written <-
                            compareAndSwapProtectedRecord
                                session
                                key
                                (ExpectVersion permitVersion)
                                (encodeJournalState (ClosingProject epoch))
                        pure $ case written of
                            Left _ ->
                                Left (SessionStaleProjectPermit (recordVersionWord permitVersion))
                            Right nextVersion -> Right (ProjectPermit nextVersion)

{- | Record the terminal @ClosedProject@ state, only from the exact Closing
epoch that authorized it. An Open journal cannot jump straight to Closed.
-}
recordClosedProject ::
    ProtectedSession session ->
    Text ->
    -- | the closing epoch recorded by 'beginClosingProject'
    Word64 ->
    ProjectPermit scope planId ->
    IO (Either SessionError ())
recordClosedProject session planDigest epoch (ProjectPermit permitVersion) =
    case projectKey planDigest of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (Left (SessionStoreFailure failure))
                Right Nothing -> pure (Left (SessionProjectMissing planDigest))
                Right (Just record) -> case decodeJournalState (protectedRecordBytes record) of
                    Nothing -> pure (Left (SessionRecordCorrupt "project journal"))
                    Just ClosedProject -> pure (Right ())
                    Just OpenProject -> pure (Left (SessionRecordCorrupt "project is not closing"))
                    Just (ClosingProject persisted)
                        | persisted /= epoch ->
                            pure (Left (SessionProjectClosing planDigest))
                        | otherwise -> do
                            written <-
                                compareAndSwapProtectedRecord
                                    session
                                    key
                                    (ExpectVersion permitVersion)
                                    (encodeJournalState ClosedProject)
                            pure $ case written of
                                Left _ ->
                                    Left
                                        ( SessionStaleProjectPermit
                                            (recordVersionWord permitVersion)
                                        )
                                Right _ -> Right ()

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
    listed <- listProtectedRecords session
    case listed of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right keys -> do
            let prefix = sessionKeyPrefix planDigest
                members =
                    [ SessionId (Text.drop (Text.length prefix) raw)
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

versionOf :: ProtectedRecord -> Word64
versionOf = recordVersionWord . protectedRecordVersion

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
sessionKey planDigest (SessionId sid) = keyFor ("session." <> planDigest <> "." <> sid)

sessionKeyPrefix :: Text -> Text
sessionKeyPrefix planDigest = "session." <> planDigest <> "."

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
openOperationSession session epoch planDigest rawSessionId (ProjectPermit permitVersion) = do
    let sid = SessionId rawSessionId
    stale <- openSessionsFor session planDigest
    case stale of
        Left failure -> pure (Left failure)
        Right (older : _) -> pure (Left (SessionOlderStillOpen older))
        Right [] -> case (projectKey planDigest, sessionKey planDigest sid) of
            (Left failure, _) -> pure (Left failure)
            (_, Left failure) -> pure (Left failure)
            (Right pKey, Right sKey) -> do
                -- Advance the shared journal first: if another holder already
                -- advanced it, this open never publishes a session record.
                advanced <-
                    compareAndSwapProtectedRecord
                        session
                        pKey
                        (ExpectVersion permitVersion)
                        (encodeFields ["open"])
                case advanced of
                    Left _ -> pure (Left (SessionStaleProjectPermit (recordVersionWord permitVersion)))
                    Right nextVersion -> do
                        written <-
                            compareAndSwapProtectedRecord
                                session
                                sKey
                                ExpectAbsent
                                (encodeFields ["open", Text.pack (show (brokerEpochWord epoch))])
                        pure $ case written of
                            Left failure -> Left (SessionStoreFailure failure)
                            Right _ ->
                                Right
                                    ( OperationSession
                                        { sessionRecordId = sid
                                        , sessionPlanDigest = planDigest
                                        , sessionBrokerGeneration = brokerEpochWord epoch
                                        }
                                    , ProjectPermit nextVersion
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
        Right keys -> do
            let prefix = sessionKeyPrefix planDigest
                candidates =
                    [ SessionId (Text.drop (Text.length prefix) raw)
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
    case sessionKey planDigest sid of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord session key
            pure $ case observed of
                Left failure -> Left (SessionStoreFailure failure)
                Right Nothing -> Right False
                Right (Just record) -> case decodeFields (protectedRecordBytes record) of
                    ("open" : _) -> Right True
                    ("closed" : _) -> Right False
                    _ -> Left (SessionRecordCorrupt "session")

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
closeOperationSession session sess (ProjectPermit permitVersion) = do
    unsettled <- unsettledOperations session sess
    case unsettled of
        Left failure -> pure (Left failure)
        Right (pending : _) -> pure (Left (SessionOperationUnsettled pending))
        Right [] -> case (projectKey (sessionPlanDigest sess), sessionKey (sessionPlanDigest sess) (sessionRecordId sess)) of
            (Left failure, _) -> pure (Left failure)
            (_, Left failure) -> pure (Left failure)
            (Right pKey, Right sKey) -> do
                observed <- readProtectedRecord session sKey
                case observed of
                    Left failure -> pure (Left (SessionStoreFailure failure))
                    Right Nothing -> pure (Left (SessionUnknown (sessionRecordId sess)))
                    Right (Just record) -> do
                        closed <-
                            compareAndSwapProtectedRecord
                                session
                                sKey
                                (ExpectVersion (protectedRecordVersion record))
                                (encodeFields ["closed", Text.pack (show (sessionBrokerGeneration sess))])
                        case closed of
                            Left failure -> pure (Left (SessionStoreFailure failure))
                            Right _ -> do
                                advanced <-
                                    compareAndSwapProtectedRecord
                                        session
                                        pKey
                                        (ExpectVersion permitVersion)
                                        (encodeFields ["open"])
                                pure $ case advanced of
                                    Left _ -> Left (SessionStaleProjectPermit (recordVersionWord permitVersion))
                                    Right nextVersion -> Right (ProjectPermit nextVersion)

-- ---------------------------------------------------------------------------
-- Operation records

operationKeyFor :: Text -> SessionId -> Text -> Either SessionError RecordKey
operationKeyFor planDigest (SessionId sid) opKey =
    keyFor ("op." <> planDigest <> "." <> sid <> "." <> opKey)

operationPrefix :: Text -> SessionId -> Text
operationPrefix planDigest (SessionId sid) = "op." <> planDigest <> "." <> sid <> "."

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
registerOperationIntent session sess opKey origin (ProjectPermit permitVersion) =
    case (operationKeyFor plan (sessionRecordId sess) opKey, projectKey plan) of
        (Left failure, _) -> pure (Left failure)
        (_, Left failure) -> pure (Left failure)
        (Right oKey, Right pKey) -> do
            live <- readSessionState session plan (sessionRecordId sess)
            case live of
                Left failure -> pure (Left failure)
                Right False -> pure (Left (SessionNotOpen (sessionRecordId sess)))
                Right True -> do
                    observed <- readProtectedRecord session oKey
                    case observed of
                        Left failure -> pure (Left (SessionStoreFailure failure))
                        Right (Just record)
                            | origin == NoHistory ->
                                pure
                                    ( Left
                                        ( SessionIntentAlreadyRecorded
                                            opKey
                                            (phaseTextOf (protectedRecordBytes record))
                                        )
                                    )
                            | phaseTextOf (protectedRecordBytes record) /= "Released" ->
                                pure
                                    ( Left
                                        ( SessionIntentOriginRefused
                                            opKey
                                            (phaseTextOf (protectedRecordBytes record))
                                        )
                                    )
                        _ -> do
                            let expectation = case observed of
                                    Right (Just record) -> ExpectVersion (protectedRecordVersion record)
                                    _ -> ExpectAbsent
                            written <-
                                compareAndSwapProtectedRecord
                                    session
                                    oKey
                                    expectation
                                    (encodeFields ["IntentRecorded", sessionIdText (sessionRecordId sess), "0"])
                            case written of
                                Left failure -> pure (Left (SessionStoreFailure failure))
                                Right _ -> do
                                    advanced <-
                                        compareAndSwapProtectedRecord
                                            session
                                            pKey
                                            (ExpectVersion permitVersion)
                                            (encodeFields ["open"])
                                    pure $ case advanced of
                                        Left _ -> Left (SessionStaleProjectPermit (recordVersionWord permitVersion))
                                        Right nextVersion -> Right (ProjectPermit nextVersion)
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
    listed <- listProtectedRecords session
    case listed of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right keys -> do
            let prefix = operationPrefix (sessionPlanDigest sess) (sessionRecordId sess)
                names = [Text.drop (Text.length prefix) raw | raw <- map recordKeyText keys, prefix `Text.isPrefixOf` raw]
            foldM step (Right []) names
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) name =
        case operationKeyFor (sessionPlanDigest sess) (sessionRecordId sess) name of
            Left failure -> pure (Left failure)
            Right key -> do
                observed <- readProtectedRecord session key
                pure $ case observed of
                    Left failure -> Left (SessionStoreFailure failure)
                    Right Nothing -> Right acc
                    Right (Just record) ->
                        case classifyRecordedPhase (phaseTextOf (protectedRecordBytes record)) of
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
fenceKey planDigest = keyFor ("fence." <> planDigest)

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
    [ "ObservedForeign"
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
    listed <- openSessionsFor session planDigest
    case listed of
        Left failure -> pure (Left failure)
        Right sessions -> foldM step (Right (RecoveredSessions 0 0)) (sort sessions)
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) sid = do
        counted <- classifySessionOperations session planDigest sid
        case counted of
            Left failure -> pure (Left failure)
            Right continuable -> case sessionKey planDigest sid of
                Left failure -> pure (Left failure)
                Right key -> do
                    observed <- readProtectedRecord session key
                    case observed of
                        Left failure -> pure (Left (SessionStoreFailure failure))
                        Right Nothing -> pure (Right acc)
                        Right (Just record) -> do
                            closed <-
                                compareAndSwapProtectedRecord
                                    session
                                    key
                                    (ExpectVersion (protectedRecordVersion record))
                                    (encodeFields ["closed", "recovered"])
                            pure $ case closed of
                                Left failure -> Left (SessionStoreFailure failure)
                                Right _ ->
                                    Right
                                        RecoveredSessions
                                            { recoveredSessionCount = recoveredSessionCount acc + 1
                                            , recoveredContinuableCount =
                                                recoveredContinuableCount acc + continuable
                                            }

classifySessionOperations ::
    ProtectedSession session ->
    Text ->
    SessionId ->
    IO (Either SessionError Int)
classifySessionOperations session planDigest sid = do
    listed <- listProtectedRecords session
    case listed of
        Left failure -> pure (Left (SessionStoreFailure failure))
        Right keys -> do
            let prefix = operationPrefix planDigest sid
                names = [Text.drop (Text.length prefix) raw | raw <- map recordKeyText keys, prefix `Text.isPrefixOf` raw]
            foldM step (Right 0) names
  where
    step (Left failure) _ = pure (Left failure)
    step (Right acc) name = case operationKeyFor planDigest sid name of
        Left failure -> pure (Left failure)
        Right key -> do
            observed <- readProtectedRecord session key
            pure $ case observed of
                Left failure -> Left (SessionStoreFailure failure)
                Right Nothing -> Right acc
                Right (Just record) ->
                    case classifyRecordedPhase (phaseTextOf (protectedRecordBytes record)) of
                        UnknownDisposition -> Left (SessionUnclassifiedPhase name (phaseTextOf (protectedRecordBytes record)))
                        Continuable -> Right (acc + 1)
                        _ -> Right acc

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
withPreparedGate session sess epoch fence opKey unknownPhase (ProjectPermit permitVersion) use
    | brokerEpochWord epoch /= sessionBrokerGeneration sess =
        pure
            ( Left
                ( SessionBrokerEpochMismatch
                    (sessionBrokerGeneration sess)
                    (brokerEpochWord epoch)
                )
            )
    | otherwise = do
        projectState <- readProjectJournalState session plan
        case projectState of
            Left failure -> pure (Left failure)
            Right ClosedProject -> pure (Left (SessionProjectClosed plan))
            -- Terminal close has been authorized, so no further operation may be
            -- prepared: this is the branch that stops a prepare racing a close.
            Right (ClosingProject _) -> pure (Left (SessionProjectClosing plan))
            Right OpenProject -> do
                live <- readSessionState session plan (sessionRecordId sess)
                case live of
                    Left failure -> pure (Left failure)
                    Right False -> pure (Left (SessionNotOpen (sessionRecordId sess)))
                    Right True -> do
                        observedFence <- currentFence session plan
                        case observedFence of
                            Left failure -> pure (Left failure)
                            Right (FenceEpoch liveEpoch)
                                | liveEpoch /= fenceEpochWord fence ->
                                    pure (Left (SessionFenceSuperseded (fenceEpochWord fence) liveEpoch))
                                | otherwise -> gateOperation liveEpoch
  where
    plan = sessionPlanDigest sess

    gateOperation liveEpoch = case (operationKeyFor plan (sessionRecordId sess) opKey, projectKey plan) of
        (Left failure, _) -> pure (Left failure)
        (_, Left failure) -> pure (Left failure)
        (Right oKey, Right pKey) -> do
            observed <- readProtectedRecord session oKey
            case observed of
                Left failure -> pure (Left (SessionStoreFailure failure))
                Right Nothing -> pure (Left (SessionOperationUnregistered opKey))
                Right (Just record) -> do
                    let recorded = phaseTextOf (protectedRecordBytes record)
                        priorFence = recordedFenceOf (protectedRecordBytes record)
                    case classifyRecordedPhase recorded of
                        UnknownDisposition -> pure (Left (SessionUnclassifiedPhase opKey recorded))
                        Settled -> pure (Left (SessionOperationSettled opKey recorded))
                        TerminalDisposition -> pure (Left (SessionOperationTerminal opKey recorded))
                        FencedRetryable
                            | priorFence >= liveEpoch ->
                                pure (Left (SessionRetryNeedsFreshFence opKey priorFence liveEpoch))
                            | otherwise -> advance oKey pKey record liveEpoch
                        Continuable -> advance oKey pKey record liveEpoch

    advance oKey pKey record liveEpoch = do
        let attempt = recordedAttempt (protectedRecordBytes record) + 1
        -- Durably record the unknown phase BEFORE the adapter can be called.
        -- 'recordDurableUnknown' is the sole 'PreparedGate' producer, so the
        -- attempt and journal version an adapter is later prepared against are
        -- the ones this write established.
        marked <-
            recordDurableUnknown
                session
                oKey
                (ExpectVersion (protectedRecordVersion record))
                unknownPhase
                plan
                opKey
                (sessionIdText (sessionRecordId sess))
                liveEpoch
                attempt
        case marked of
            Left failure -> pure (Left (SessionStoreFailure failure))
            Right gate -> do
                advanced <-
                    compareAndSwapProtectedRecord
                        session
                        pKey
                        (ExpectVersion permitVersion)
                        (encodeFields ["open"])
                case advanced of
                    Left _ -> pure (Left (SessionStaleProjectPermit (recordVersionWord permitVersion)))
                    Right nextVersion -> use gate (ProjectPermit nextVersion)

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
acknowledgeOutcome session sess gate observedPhase result (ProjectPermit permitVersion) =
    case ( operationKeyFor plan (sessionRecordId sess) (preparedGateOperation gate)
         , projectKey plan
         ) of
        (Left failure, _) -> pure (Left failure)
        (_, Left failure) -> pure (Left failure)
        (Right oKey, Right pKey) -> do
            observed <- readProtectedRecord session oKey
            case observed of
                Left failure -> pure (Left (SessionStoreFailure failure))
                Right Nothing -> pure (Left (SessionOperationUnregistered (preparedGateOperation gate)))
                Right (Just record)
                    | versionOf record /= preparedGateJournalVersion gate ->
                        pure
                            ( Left
                                ( SessionStaleJournalVersion
                                    (preparedGateJournalVersion gate)
                                    (versionOf record)
                                )
                            )
                    | otherwise -> do
                        settled <-
                            compareAndSwapProtectedRecord
                                session
                                oKey
                                (ExpectVersion (protectedRecordVersion record))
                                ( encodeFields
                                    [ observedPhase
                                    , sessionIdText (sessionRecordId sess)
                                    , Text.pack (show (preparedGateFence gate))
                                    , Text.pack (show (preparedGateAttempt gate))
                                    ]
                                )
                        case settled of
                            Left failure -> pure (Left (SessionStoreFailure failure))
                            Right _ -> do
                                advanced <-
                                    compareAndSwapProtectedRecord
                                        session
                                        pKey
                                        (ExpectVersion permitVersion)
                                        (encodeFields ["open"])
                                pure $ case advanced of
                                    Left _ -> Left (SessionStaleProjectPermit (recordVersionWord permitVersion))
                                    Right nextVersion ->
                                        Right
                                            ( OperationAdvance
                                                result
                                                (ProjectPermit nextVersion)
                                            )
  where
    plan = sessionPlanDigest sess

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
    | -- | consumed version, then the version actually on the record
      SessionStaleJournalVersion Word64 Word64
    deriving (Eq, Show)

sessionErrorMessage :: SessionError -> String
sessionErrorMessage err = case err of
    SessionStoreFailure failure -> "session: " <> Text.unpack (protectedErrorMessage failure)
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
    SessionStaleJournalVersion consumed actual ->
        "session: journal version " <> show consumed <> " was superseded by " <> show actual
