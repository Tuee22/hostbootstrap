{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The one seam of kernel primitives, and the producers that turn them into the
four ownership clauses.

@development_plan_standards.md § EE@'s four clauses are one transaction, so this
module is the one place that transaction is written. What differs between a
POSIX host and a Windows host is the /primitive/ each kernel supplies — a row of
the frame table (§ LL) — never a clause written twice.

The seam is a record of primitives and nothing else. Three things it
deliberately does not carry:

  * **No command runner.** An external effect that has to happen between the
    origin record and the identity binding — launching an instance, creating a
    cluster — travels as a described command through the one interpreter
    (§ KK). The moment a seam can run a string, it is a shell again.
  * **No pathname policy.** The target an owner names rides on the clause tokens
    (see "HostBootstrap.Ownership.Clause"); the seam never derives one, so it
    never decides which object an owner meant.
  * **No durable state.** The origin record a re-entry is built from is the
    caller's own, read back through the store that published it, so the seam
    never becomes a second place an ownership fact lives.
  * **No clause 1 or clause 2 field.** Exclusive entry is the protected store's
    own OS-released entry and the durable record is that store's
    compare-and-swap. A second durable record beside the store would be a second
    source of truth. The seam's /exclusive open/ is a different thing and is a
    field: it opens one already-existing named object, without following a link,
    inside an entry the store already holds.

Not every owned object is one a kernel answers for. A provider instance's stable
identity is answered by the provider itself, over a described command through the
one interpreter, so its observation arrives here as a /value/ rather than as a
probe this module could make. The clause producers therefore come in two faces
over the same four tokens: the kernel face, which reads a row's
'rowObserveIdentity', and the __reported__ face, which is handed the 'Origin' a
total classification produced. Each shared computation — the record an origin
describes, the binding attached to it, the conflict a re-observation reports — is
written once and used by both, so the two faces differ in who answers the
observation and never in what a clause means.

The reported face takes no row, and that is its honest signature rather than an
omission: it reaches no kernel primitive, so a row's declaration has nothing to
say about it. What it does still take is the protected entry, because clause 1 is
that entry and clause 2 is that store's compare-and-swap on either face.

The handle a row mints is closed existentially, so a handle from one row cannot
enter another, and a caller cannot name the type at all.

What a row can hold is declared rather than discovered. 'OwnershipCapabilities'
says which clauses this kernel supports, and 'clauseRefusal' turns that
declaration into the exact refusal a row owes — a total function of a value,
applied before any mutation, so @Unsupported@ is decided by application rather
than by a stand-in that has to be trusted to have been reached (§ NN).
-}
module HostBootstrap.Ownership.Primitive (
    -- * The seam
    OwnershipPrimitive (..),
    OwnershipRow,
    ownershipRow,
    withOwnershipRow,
    readWholeObject,

    -- * What a row can hold
    OwnershipCapabilities (..),
    OwnershipClause (..),
    clauseRefusal,

    -- * The clause producers, over an object a kernel answers for
    enterOwnedObject,
    StoredOriginRecord,
    reenterStoredOwnedObject,
    recordOwnedOrigin,
    createOwnedDirectory,
    publishOwnedFile,
    bindOwnedIdentity,
    reobserveOwnedIdentity,
    withReobservedIdentity,
    releaseOwnedObject,
    resumeOwnedRemoval,

    -- * The clause producers, over an object an authority reports on
    enterReportedObject,
    reenterStoredReportedObject,
    recordReportedOrigin,
    bindReportedIdentity,
    reobserveReportedIdentity,
    releaseReportedObject,
    resumeReportedRemoval,
)
where

import Control.Exception (SomeException, mask, throwIO, try)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Ownership.Internal (
    Bound (Bound),
    Entered (Entered),
    OwnedTargetPath,
    Recorded (Recorded),
    Releasable (Releasable),
    boundEvidence,
    enteredEvidence,
    recordedEvidence,
    releasableEvidence,
    enteredSession,
    recordedSession,
    boundSession,
    releasableSession,
 )
import HostBootstrap.Ownership.Object (
    ConflictReport (..),
    ObjectIdentity,
    OwnerClaim,
    ObjectKind (OwnedDirectory, OwnedFile, ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OriginRecord,
    OwnershipFault (
        OwnershipConflict,
        OwnershipMalformed,
        OwnershipOccupied,
        OwnershipUnsupported
    ),
    Payload,
    bindOriginRecord,
    originRecord,
    originRecordBinding,
    originRecordKind,
    originRecordOrigin,
    payloadBytes,
    payloadDigest,
    storeFault,
 )
import HostBootstrap.Ownership.Tape (StoredOriginRecord, storedOriginRecord)
import HostBootstrap.Protected (ProtectedSession, verifyProtectedSession)

-- ---------------------------------------------------------------------------
-- The seam

{- | The primitives one kernel supplies, closed over the handle type it mints.

Every field is a primitive: it does one kernel operation and classifies its own
platform failure into the closed fault sum, so nothing above a row ever sees a
platform's error numbering and no driver can come to depend on one.
-}
data OwnershipPrimitive handle = OwnershipPrimitive
    { rowCapabilities :: OwnershipCapabilities
    -- ^ Which clauses this kernel can hold.
    , rowObserveIdentity :: OwnedTargetPath -> IO (Either OwnershipFault (Maybe ObjectIdentity))
    {- ^ The object's stable kernel identity, or an authoritative absence. A
    probe failure is a fault and never a false absence (§ CC).
    -}
    , rowOpenExclusive :: OwnedTargetPath -> IO (Either OwnershipFault handle)
    {- ^ Open one already-existing named object exclusively, without following
    a link.
    -}
    , rowCreateDirectory :: OwnedTargetPath -> IO (Either OwnershipFault ())
    -- ^ Create exactly one directory, refusing if it is already there.
    , rowCreateFile :: OwnedTargetPath -> ByteString -> IO (Either OwnershipFault ())
    -- ^ Write a whole file and sync it, at a name nothing else holds.
    , rowLinkNoReplace :: OwnedTargetPath -> OwnedTargetPath -> IO (Either OwnershipFault ())
    {- ^ Give @source@ a second name at @target@ atomically, refusing rather
    than replacing. The source name is left in place, because the kernel
    primitive is a link: an owner that wanted a move withdraws the staging
    name itself, and one that wanted a second durable name — the host wall's
    armed stage — keeps both.
    -}
    , rowReadObject :: handle -> IO (Either OwnershipFault ByteString)
    -- ^ Read the whole object behind an open handle.
    , rowRemoveObject :: OwnedTargetPath -> IO (Either OwnershipFault ())
    -- ^ Remove exactly the named object.
    , rowCloseHandle :: handle -> IO (Either OwnershipFault ())
    -- ^ Release one handle this row minted.
    , rowSyncParent :: OwnedTargetPath -> IO (Either OwnershipFault ())
    -- ^ Make the parent directory's own change durable.
    }

{- | One row, with its handle type sealed away.

A caller holds a row and can run its primitives; it cannot name the handle type,
so a handle minted by one row has no type at which it could be handed to
another.
-}
data OwnershipRow = forall handle. OwnershipRow (OwnershipPrimitive handle)

-- | Seal a row's handle type.
ownershipRow :: OwnershipPrimitive handle -> OwnershipRow
ownershipRow = OwnershipRow

{- | Run one continuation against a row's primitives.

Rank-2 in the handle, so the continuation is polymorphic in it and cannot leak
a handle past the row that minted it.
-}
withOwnershipRow ::
    OwnershipRow ->
    (forall handle. OwnershipPrimitive handle -> result) ->
    result
withOwnershipRow (OwnershipRow row) use = use row

{- | Read one whole object inside the scope of its exclusive kernel handle.

Acquisition and the transfer to cleanup are masked; payload reading restores the
caller's masking state. Every opened handle is closed before return or throw.
A thrown read exception wins even if close also throws. For typed results, a
read fault wins a typed close fault; a successful read reports a failed close.
This raw-row transaction carries no origin authority and returns no handle.
-}
readWholeObject :: OwnershipRow -> OwnedTargetPath -> IO (Either OwnershipFault ByteString)
readWholeObject row target =
    withOwnershipRow row $ \primitives ->
        mask $ \restore -> do
            opened <- rowOpenExclusive primitives target
            case opened of
                Left fault -> pure (Left fault)
                Right handle -> do
                    readResult <- attempt (restore (rowReadObject primitives handle))
                    closeResult <- attempt (rowCloseHandle primitives handle)
                    case readResult of
                        Left failure -> throwIO failure
                        Right response -> case closeResult of
                            Left failure -> throwIO failure
                            Right closed -> pure $ case response of
                                Left fault -> Left fault
                                Right bytes -> bytes <$ closed
  where
    attempt :: IO value -> IO (Either SomeException value)
    attempt = try

-- ---------------------------------------------------------------------------
-- What a row can hold

{- | What this kernel can actually do, declared by the row itself.

A row that cannot hold a clause says so here and mints no receipt at all, rather
than minting a weaker one. Declaring it is what makes the refusal checkable by
application: nothing has to run for 'clauseRefusal' to be exercised over every
combination.
-}
data OwnershipCapabilities = OwnershipCapabilities
    { holdsStableIdentity :: Bool
    -- ^ The kernel answers a stable identity for an object.
    , holdsNoReplacePublication :: Bool
    -- ^ A name can be published atomically, refusing rather than replacing.
    , holdsDurableParentSync :: Bool
    -- ^ The parent directory's own change can be made durable.
    }
    deriving (Eq, Show)

-- | The four clauses, named so a refusal can say which one is missing.
data OwnershipClause
    = ClauseEnter
    | ClauseRecord
    | ClauseBind
    | ClauseRelease
    deriving (Eq, Ord, Show, Enum, Bounded)

{- | The refusal a row owes for a clause it cannot hold, or 'Nothing'.

Total, and a function of the declaration alone. Kernel-face producers apply it
before a primitive: entry uses ClauseEnter; recording, directory creation and
object removal use ClauseRecord; binding uses ClauseBind; file publication uses
both ClauseRecord and ClauseBind; re-observation uses ClauseRelease. Publication
needs no-replace linking and parent sync, and removal needs parent sync as well
as the identity already re-observed. The reported face has no kernel row.

Which capability each clause needs is the whole content:

  * entering needs the identity read, because clause 1's observation is what the
    origin record is about;
  * recording needs the identity read and a durable parent, because a record
    that is not on the disk when the object appears answers nothing;
  * binding needs the identity read and the no-replace publication, because
    clause 3 binds what the kernel knows about an object this run created rather
    than adopted;
  * releasing needs the identity read, because clause 4 is a re-observation.
-}
clauseRefusal :: OwnershipCapabilities -> OwnershipClause -> Maybe OwnershipFault
clauseRefusal capabilities clause = case missing of
    [] -> Nothing
    reasons ->
        Just
            ( OwnershipUnsupported
                ( "this host cannot hold ownership clause "
                    <> clauseName clause
                    <> ": it supplies no "
                    <> Text.intercalate ", no " reasons
                )
            )
  where
    missing =
        [ reason
        | (needed, reason) <- required clause
        , not needed
        ]

    required ClauseEnter = [identityRequirement]
    required ClauseRecord = [identityRequirement, parentRequirement]
    required ClauseBind = [identityRequirement, publicationRequirement]
    required ClauseRelease = [identityRequirement]

    identityRequirement = (holdsStableIdentity capabilities, "stable object identity")
    parentRequirement = (holdsDurableParentSync capabilities, "durable parent directory")
    publicationRequirement =
        (holdsNoReplacePublication capabilities, "atomic no-replace publication")

clauseName :: OwnershipClause -> Text
clauseName ClauseEnter = "1 (exclusive entry)"
clauseName ClauseRecord = "2 (durable origin record)"
clauseName ClauseBind = "3 (identity binding)"
clauseName ClauseRelease = "4 (conditional release)"

-- ---------------------------------------------------------------------------
-- The kernel clause producers, over an object a kernel answers for

{- | Clause 1: observe the target inside the entry that protects it.

The 'ProtectedSession' argument is the whole of clause 1 — the store's entry is
the exclusive one, and the OS releases it if this process dies — so this
producer adds the observation that entry makes meaningful and nothing else. The
object index is introduced here, fresh, and the continuation is rank-2 in it, so
every later clause is about this object and no other.
-}
enterOwnedObject ::
    OwnershipRow ->
    ProtectedSession session ->
    OwnedTargetPath ->
    (forall object. Entered session object -> IO (Either OwnershipFault result)) ->
    IO (Either OwnershipFault result)
enterOwnedObject row session target use =
    withOwnershipRow row $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseEnter of
            Just refusal -> pure (Left refusal)
            Nothing -> withLiveOwnershipEntry session $ do
                observed <- rowObserveIdentity primitives target
                case observed of
                    Left fault -> pure (Left fault)
                    Right prior -> use (Entered session target (originOf prior))

originOf :: Maybe ObjectIdentity -> Origin
originOf Nothing = OriginAbsent
originOf (Just identity) = OriginPresent identity

{- | Re-enter ownership only from evidence read under this protected entry.

The stored wrapper has the entry's nominal index and no public constructor.
Only the protected tape reader mints it. The release-capability check happens
before the body is projected, and a record without a binding is malformed;
neither refusal reaches a kernel primitive or the caller's continuation.
A fresh object index keeps the bound evidence tied to this target. The shared
projection publishes nothing and admits every bound origin kind; owners retain
their exact subject, claim and origin policy checks.
-}
reenterStoredOwnedObject ::
    OwnershipRow ->
    ProtectedSession session ->
    OwnedTargetPath ->
    StoredOriginRecord session ->
    (forall object. Bound session object -> IO (Either OwnershipFault result)) ->
    IO (Either OwnershipFault result)
reenterStoredOwnedObject row session target stored use =
    withOwnershipRow row $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseRelease of
            Just refusal -> pure (Left refusal)
            Nothing -> withLiveOwnershipEntry session $
                reenterBoundRecord session target (storedOriginRecord stored) use

{- | Re-enter reported ownership from the same entry's protected tape read.

The nominal stored wrapper cannot be supplied by an in-memory origin record.
This face takes no row, publishes nothing and reaches no kernel primitive.
A kernel kind is unsupported; an unbound reported record is malformed. Both
refusals happen before the continuation. Owners validate the exact stored
subject and claim before presenting this read evidence.
-}
reenterStoredReportedObject ::
    ProtectedSession session ->
    OwnedTargetPath ->
    StoredOriginRecord session ->
    (forall object. Bound session object -> IO (Either OwnershipFault result)) ->
    IO (Either OwnershipFault result)
reenterStoredReportedObject session target stored use =
    withLiveOwnershipEntry session $
        case originRecordKind record of
            ReportedObject _ -> reenterBoundRecord session target record use
            _ ->
                pure
                    (Left (OwnershipUnsupported "this record describes a kernel object, not a reported object"))
  where
    record = storedOriginRecord stored

-- | Project the one bound-record fact both re-entry faces require.
reenterBoundRecord ::
    ProtectedSession session ->
    OwnedTargetPath ->
    OriginRecord ->
    (forall object. Bound session object -> IO (Either OwnershipFault result)) ->
    IO (Either OwnershipFault result)
reenterBoundRecord session target record use =
    case originRecordBinding record of
        Nothing ->
            pure
                ( Left
                    ( OwnershipMalformed
                        ( "this record names no identity binding, so it authorizes"
                            <> " no release"
                        )
                    )
                )
        Just identity -> use (Bound session target record identity)

{- | Clause 2: publish the origin record before the object exists.

The publication itself is a continuation, because the durable record is the
protected store's compare-and-swap and a second durable record beside the store
would be a second source of truth. What this producer owns is that the record
says what was actually observed, that it is unbound, and that it is on the disk
before the token exists.
-}
recordOwnedOrigin ::
    OwnershipRow ->
    Entered session object ->
    ObjectKind ->
    (OriginRecord -> IO (Either OwnershipFault ())) ->
    IO (Either OwnershipFault (Recorded session object))
recordOwnedOrigin row entered kind publish =
    withOwnershipRow row $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseRecord of
            Just refusal -> pure (Left refusal)
            Nothing -> recordOrigin entered kind publish

{- | Create the owned directory the record describes, and read its identity.

A directory a run merely found is not a directory it created, so an origin that
already names an identity is an occupied target rather than something to adopt.
-}
createOwnedDirectory ::
    OwnershipRow ->
    Recorded session object ->
    IO (Either OwnershipFault ObjectIdentity)
createOwnedDirectory row recorded =
    withOwnershipRow row $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseRecord of
            Just refusal -> pure (Left refusal)
            Nothing ->
                recordedEvidenceOf recorded $ \target record ->
                    case originRecordOrigin record of
                        OriginPresent _ ->
                            pure (Left (OwnershipOccupied "the recorded origin was occupied before this run"))
                        OriginAbsent ->
                            case originRecordKind record of
                                OwnedFile _ ->
                                    pure (Left (OwnershipUnsupported "this record describes a file, not a directory"))
                                ReportedObject _ -> pure (Left (reportedRecordRefusal "a directory"))
                                OwnedDirectory -> do
                                    created <- rowCreateDirectory primitives target
                                    case created of
                                        Left fault -> pure (Left fault)
                                        Right () -> do
                                            synced <- rowSyncParent primitives target
                                            case synced of
                                                Left fault -> pure (Left fault)
                                                Right () -> identityOfCreated primitives target

{- | Publish the owned file the record describes, and read its identity.

Both creating producers require a recorded absence before inspecting the kind.
A present origin is occupied and reaches no primitive. Failed staging creation
preserves its fault without removal: it may have refused another object's name.
After successful staging creation, a failed link attempts staging withdrawal
best-effort and preserves the link's fault.

The payload is written, linked under a name nothing else holds, and the staging
name is then withdrawn, so a target that already exists is refused rather than
replaced: a generated object cannot coexist with one already there, and clause 3
must bind an object this run created. The link and the withdrawal are separate
because the kernel primitive is a link; an owner that needs the staging name to
survive the publication — the host wall's armed stage — composes the same two
steps differently.
-}
publishOwnedFile ::
    OwnershipRow ->
    Recorded session object ->
    Payload ->
    OwnedTargetPath ->
    IO (Either OwnershipFault ObjectIdentity)
publishOwnedFile row recorded payload staging =
    withOwnershipRow row $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseRecord of
            Just refusal -> pure (Left refusal)
            Nothing ->
                case clauseRefusal (rowCapabilities primitives) ClauseBind of
                    Just refusal -> pure (Left refusal)
                    Nothing ->
                        recordedEvidenceOf recorded $ \target record ->
                            case originRecordOrigin record of
                                OriginPresent _ ->
                                    pure (Left (OwnershipOccupied "the recorded origin was occupied before this run"))
                                OriginAbsent ->
                                    case originRecordKind record of
                                        OwnedDirectory ->
                                            pure (Left (OwnershipUnsupported "this record describes a directory, not a file"))
                                        ReportedObject _ -> pure (Left (reportedRecordRefusal "a file"))
                                        OwnedFile digest
                                            | digest /= payloadDigest payload ->
                                                pure
                                                    ( Left
                                                        ( OwnershipUnsupported
                                                            "the payload offered is not the payload the origin record names"
                                                        )
                                                    )
                                            | otherwise -> do
                                                written <- rowCreateFile primitives staging (payloadBytes payload)
                                                case written of
                                                    Left fault -> pure (Left fault)
                                                    Right () -> do
                                                        published <- rowLinkNoReplace primitives staging target
                                                        case published of
                                                            Left fault -> do
                                                                _ <- rowRemoveObject primitives staging
                                                                pure (Left fault)
                                                            Right () -> do
                                                                withdrawn <- rowRemoveObject primitives staging
                                                                case withdrawn of
                                                                    Left fault -> pure (Left fault)
                                                                    Right () -> do
                                                                        synced <- rowSyncParent primitives target
                                                                        case synced of
                                                                            Left fault -> pure (Left fault)
                                                                            Right () -> identityOfCreated primitives target

{- | Clause 3: bind the created object's own identity to the record.

The binding is attached to the record the previous clause published and the
result is re-published through the caller's own durable write, so the identity a
release will compare against is the one on the disk rather than one held in
memory by whoever asked.
-}
bindOwnedIdentity ::
    OwnershipRow ->
    Recorded session object ->
    ObjectIdentity ->
    (OriginRecord -> IO (Either OwnershipFault ())) ->
    IO (Either OwnershipFault (Bound session object))
bindOwnedIdentity row recorded identity publish =
    withOwnershipRow row $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseBind of
            Just refusal -> pure (Left refusal)
            Nothing -> bindReportedIdentity recorded identity publish

{- | Clause 4's precondition: re-observe the target and require the bound
identity.

An object that is gone and an object that has been replaced are both conflicts
rather than successes, and both are reported with the identity release expected
and the one it observed, so an operator learns which of the two happened.
-}
reobserveOwnedIdentity ::
    OwnershipRow ->
    Bound session object ->
    IO (Either OwnershipFault (Releasable session object))
reobserveOwnedIdentity row bound =
    withOwnershipRow row $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseRelease of
            Just refusal -> pure (Left refusal)
            Nothing -> withLiveOwnershipEntry (boundSession bound) $
                boundEvidenceOf bound $ \target _record _identity -> do
                    observed <- rowObserveIdentity primitives target
                    pure $ case observed of
                        Left fault -> Left fault
                        Right current -> reobserveReportedIdentity bound (originOf current)

{- | Act through this row only while the target still has the expected identity.

The clause declaration is checked before observing. The identity comparison is
the same one reported and kernel re-observation use. Observation and act are
separate kernel operations; a non-cooperating replacement in between remains
possible.
-}
withReobservedIdentity ::
    OwnershipRow ->
    OwnedTargetPath ->
    ObjectIdentity ->
    (forall handle. OwnershipPrimitive handle -> IO (Either OwnershipFault result)) ->
    IO (Either OwnershipFault result)
withReobservedIdentity row target identity act =
    withOwnershipRow row $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseRelease of
            Just refusal -> pure (Left refusal)
            Nothing -> do
                observed <- rowObserveIdentity primitives target
                case observed of
                    Left fault -> pure (Left fault)
                    Right current -> case requireObservedIdentity target identity (originOf current) of
                        Left fault -> pure (Left fault)
                        Right () -> act primitives

{- | Clause 4: remove the object, then forget the record.

In that order, because a record removed first would leave an object nobody
claims, while an object removed first leaves a record whose target is already
gone — which the next run reads as its own crash window and resolves.
-}
releaseOwnedObject ::
    OwnershipRow ->
    Releasable session object ->
    (OriginRecord -> IO (Either OwnershipFault ())) ->
    IO (Either OwnershipFault ())
releaseOwnedObject row releasable forget =
    withOwnershipRow row $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseRecord of
            Just refusal -> pure (Left refusal)
            Nothing ->
                releasableEvidenceOf releasable $ \target record _identity ->
                    case originRecordKind record of
                        ReportedObject _ -> pure (Left (OwnershipMalformed "a reported object cannot use kernel removal"))
                        _ -> do
                            removed <- rowRemoveObject primitives target
                            case removed of
                                Left fault -> pure (Left fault)
                                Right () -> do
                                    synced <- rowSyncParent primitives target
                                    case synced of
                                        Left fault -> pure (Left fault)
                                        Right () -> forget record

{- | Finish a kernel removal whose object is already absent.

The retained binding, live entry, declared clauses and fresh kernel absence are
required. A present object, including the old identity, is never removed here.
The parent is synchronized before the caller forgets the retained record.
-}
resumeOwnedRemoval ::
    OwnershipRow ->
    Bound session object ->
    (OriginRecord -> IO (Either OwnershipFault ())) ->
    IO (Either OwnershipFault ())
resumeOwnedRemoval row bound forget =
    withOwnershipRow row $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseRelease of
            Just refusal -> pure (Left refusal)
            Nothing -> case clauseRefusal (rowCapabilities primitives) ClauseRecord of
                Just refusal -> pure (Left refusal)
                Nothing -> withLiveOwnershipEntry (boundSession bound) $
                    boundEvidenceOf bound $ \target record _identity ->
                        case originRecordKind record of
                            ReportedObject _ -> pure (Left (OwnershipUnsupported "a reported object cannot use kernel removal recovery"))
                            _ | originRecordOrigin record /= OriginAbsent ->
                                    pure (Left (OwnershipOccupied "the kernel removal record does not name a created object"))
                              | otherwise -> do
                                    observed <- rowObserveIdentity primitives target
                                    case observed of
                                        Left fault -> pure (Left fault)
                                        Right (Just identity) -> pure (Left (releaseConflict target OriginAbsent (OriginPresent identity)))
                                        Right Nothing -> do
                                            synced <- rowSyncParent primitives target
                                            case synced of
                                                Left fault -> pure (Left fault)
                                                Right () -> forget record

-- ---------------------------------------------------------------------------
-- The five clause producers, over an object an authority reports on

{- | Clause 1, where the observation is an answer rather than a probe.

The kernel face reads the target through a row; here the target is a name in
another authority's namespace — a provider instance, a cluster — and only that
authority can say what is at it. The classification of its described command's
outcome arrives as an 'Origin', which is the same value 'enterOwnedObject'
derives from a row's identity read, so everything downstream is identical.

What is unchanged is the whole of clause 1: the 'ProtectedSession' argument is
the exclusive entry the kernel releases when this process ends. The object index
is introduced here, fresh, and the continuation is rank-2 in it, so every later
clause is about this object and no other.
-}
enterReportedObject ::
    ProtectedSession session ->
    OwnedTargetPath ->
    -- | what the owning authority reported is at the target
    Origin ->
    (forall object. Entered session object -> IO (Either OwnershipFault result)) ->
    IO (Either OwnershipFault result)
enterReportedObject session target observed use =
    withLiveOwnershipEntry session (use (Entered session target observed))

{- | Clause 2, written once and used by both faces.

Neither face publishes the record itself: the durable record is the protected
store's compare-and-swap on either, so the publication is a continuation and this
producer owns only that the record says what was observed, that it is unbound,
and that it is durable before the token exists.

The kernel face reaches this through its own clause gate, because a row that
cannot make a parent durable cannot hold clause 2 at all. The reported face
reaches it directly, because there is no row for that gate to ask.
-}
recordReportedOrigin ::
    Entered session object ->
    OwnerClaim ->
    (OriginRecord -> IO (Either OwnershipFault ())) ->
    IO (Either OwnershipFault (Recorded session object))
recordReportedOrigin entered claim publish = recordOrigin entered (ReportedObject claim) publish

recordOrigin ::
    Entered session object ->
    ObjectKind ->
    (OriginRecord -> IO (Either OwnershipFault ())) ->
    IO (Either OwnershipFault (Recorded session object))
recordOrigin entered kind publish =
    enteredEvidenceOf entered $ \target origin -> do
        let record = originRecord kind origin
        published <- publish record
        pure (fmap (const (Recorded (enteredSession entered) target record)) published)

{- | Clause 3, written once and used by both faces.

The identity is a parameter on either face, because clause 3 binds what was
observed of an object this transaction created and the creation is not the seam's
— a directory the row made, or an instance a described command launched. What
this producer owns is that the binding attaches to the record clause 2 published
and is itself durable before the token exists.
-}
bindReportedIdentity ::
    Recorded session object ->
    ObjectIdentity ->
    (OriginRecord -> IO (Either OwnershipFault ())) ->
    IO (Either OwnershipFault (Bound session object))
bindReportedIdentity recorded identity publish =
    recordedEvidenceOf recorded $ \target record ->
        case bindOriginRecord identity record of
            Left fault -> pure (Left fault)
            Right bound -> do
                published <- publish bound
                pure (fmap (const (Bound (recordedSession recorded) target bound identity)) published)

{- | Clause 4's precondition, written once and used by both faces.

Pure, because both faces have already made their observation by the time the
question is asked: the kernel face read it through a row and the reported face
was handed it. An object that is gone and an object that has been replaced are
both conflicts rather than successes, and both report the identity release
expected beside the one observed, so an operator learns which of the two
happened.
-}
reobserveReportedIdentity ::
    Bound session object ->
    -- | what the owning authority reported is at the target now
    Origin ->
    Either OwnershipFault (Releasable session object)
reobserveReportedIdentity bound observed =
    boundEvidenceOf bound $ \target record identity -> do
        requireObservedIdentity target identity observed
        pure (Releasable (boundSession bound) target record identity)

-- | One identity comparison for both re-observation faces and conditional acts.
requireObservedIdentity :: OwnedTargetPath -> ObjectIdentity -> Origin -> Either OwnershipFault ()
requireObservedIdentity target identity observed =
    case observed of
        OriginPresent current
            | current == identity -> Right ()
        _ -> Left (releaseConflict target (OriginPresent identity) observed)

{- | Clause 4, where the removal was a described command.

The kernel face removes the object through a row primitive and then forgets the
record. The reported face cannot: removing a provider instance is an effect
outside this process, so it happens between the re-observation and this call, and
what is presented here is the authority's answer /after/ it. The order clause 4
requires is therefore still the order the program has — an object removed first,
a record forgotten second — and the answer is what decides whether the second
step is reached at all.

A target that is still there is a conflict rather than a success, because a
record forgotten over a surviving object is exactly the orphan clause 4 exists to
prevent.
-}
releaseReportedObject ::
    Releasable session object ->
    -- | what the owning authority reported after the removal
    Origin ->
    (OriginRecord -> IO (Either OwnershipFault ())) ->
    IO (Either OwnershipFault ())
releaseReportedObject releasable observed forget =
    releasableEvidenceOf releasable $ \target record _identity ->
        case observed of
            OriginAbsent -> forget record
            OriginPresent _ -> pure (Left (releaseConflict target OriginAbsent observed))

{- | Finish an interrupted reported removal from its retained binding.

A fresh absence admits only the record cleanup; a present object is refused,
including the formerly bound identity. Ordinary re-observation still requires
that exact identity before issuing a removal. This recovery consumes the same
live protected-entry floor and clause-4 cleanup as the ordinary reported act.
-}
resumeReportedRemoval ::
    Bound session object ->
    Origin ->
    (OriginRecord -> IO (Either OwnershipFault ())) ->
    IO (Either OwnershipFault ())
resumeReportedRemoval bound observed forget =
    withLiveOwnershipEntry (boundSession bound) $
        boundEvidenceOf bound $ \target record identity ->
            case observed of
                OriginAbsent ->
                    releaseReportedObject
                        (Releasable (boundSession bound) target record identity)
                        OriginAbsent
                        forget
                OriginPresent _ ->
                    pure (Left (releaseConflict target OriginAbsent observed))

{- | The refusal a kernel producer owes a record about an object it does not
answer for.

The reported face's object is created by a described command, so no kernel
primitive here can make one — and a producer that quietly treated it as a
directory or a file would bind an identity to something it never created.
-}
reportedRecordRefusal :: Text -> OwnershipFault
reportedRecordRefusal wanted =
    OwnershipUnsupported
        ( "this record describes an object another authority owns, not "
            <> wanted
            <> "; no kernel primitive creates one"
        )

-- | The one conflict a release reports, so both faces say the same thing.
releaseConflict :: OwnedTargetPath -> Origin -> Origin -> OwnershipFault
releaseConflict target expected observed =
    OwnershipConflict
        ConflictReport
            { conflictSubject = Text.pack target
            , conflictExpected = expected
            , conflictObserved = observed
            }

-- ---------------------------------------------------------------------------
-- Shared steps

{- | Project evidence only inside the token's actual live entry.

The effectful projections check the shared runtime floor before the callback.
The bound projection remains pure for reported identity comparison; its successor
retains the same session and the next effect checks it again.
-}
enteredEvidenceOf ::
    Entered session object ->
    (OwnedTargetPath -> Origin -> IO (Either OwnershipFault result)) ->
    IO (Either OwnershipFault result)
enteredEvidenceOf token use =
    withLiveOwnershipEntry (enteredSession token) (enteredEvidence use token)

recordedEvidenceOf ::
    Recorded session object ->
    (OwnedTargetPath -> OriginRecord -> IO (Either OwnershipFault result)) ->
    IO (Either OwnershipFault result)
recordedEvidenceOf token use =
    withLiveOwnershipEntry (recordedSession token) (recordedEvidence use token)

boundEvidenceOf ::
    Bound session object -> (OwnedTargetPath -> OriginRecord -> ObjectIdentity -> result) -> result
boundEvidenceOf = flip boundEvidence

releasableEvidenceOf ::
    Releasable session object ->
    (OwnedTargetPath -> OriginRecord -> ObjectIdentity -> IO (Either OwnershipFault result)) ->
    IO (Either OwnershipFault result)
releasableEvidenceOf token use =
    withLiveOwnershipEntry (releasableSession token) (releasableEvidence use token)

-- | Consume the same live-entry floor as protected-store effects.
withLiveOwnershipEntry ::
    ProtectedSession session ->
    IO (Either OwnershipFault result) ->
    IO (Either OwnershipFault result)
withLiveOwnershipEntry session action = do
    checked <- verifyProtectedSession session
    case checked of
        Left failure -> pure (Left (storeFault "use the ownership entry" failure))
        Right () -> action

{- | Read the identity of an object this transaction has just created.

An absence here is not a normal outcome: the object was created a moment ago
inside an entry nothing else can hold, so the kernel answering "nothing is
there" is an occupied-then-vanished target rather than a state to continue from.
-}
identityOfCreated ::
    OwnershipPrimitive handle ->
    OwnedTargetPath ->
    IO (Either OwnershipFault ObjectIdentity)
identityOfCreated primitives target = do
    observed <- rowObserveIdentity primitives target
    pure $ case observed of
        Left fault -> Left fault
        Right Nothing ->
            Left (OwnershipOccupied "the object this transaction created is no longer there")
        Right (Just identity) -> Right identity
