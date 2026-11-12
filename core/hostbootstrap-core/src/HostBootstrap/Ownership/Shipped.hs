{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The frame table's third ownership row: the one that runs a transaction
where the object is, rather than where the caller is.

@development_plan_standards.md § EE@'s four clauses are one transaction, written
once in "HostBootstrap.Ownership.Primitive" and held by one platform row
(§ LL). Some objects, though, are not on the machine that decides to own them —
a path inside a provider guest, a durable root inside a VM. This module is how
that transaction reaches them, and it is a **transport rather than a third
implementation of the clauses**: what executes on the far side is the very same
seam over the frame's selected host row: POSIX in a Linux guest, and the
outer host's own row under an empty context.

The transaction travels as **one value**. That is what keeps clause 1 a kernel
fact: the receiving process opens the protected store the transaction names,
holds its exclusive entry for exactly as long as it lives, and the kernel
releases that entry when the process ends — however it ends. A per-primitive
protocol would put the entry back in the caller's hands and make its release
something that has to be correct on every error path.

The crossing itself is not this module's. The
[authenticated-handoff phase](../../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
already carries one opaque transaction out and one opaque outcome back over a
private protocol channel, launches the child into its own process group from the
lift's one fold, and ends that group on every exit path. It deliberately
interprets nothing, and says so: the phase that owns an object installs the
interpreter that produces its outcome. This module is that interpreter for owned
objects, and it adds no second rendering of "cross into this frame".

An **empty** lift context addresses this machine. That is not a degenerate case
to be optimized away: it is how a local transaction that must outlive its
launcher's own bracket is expressed, because a launcher's cleanup is exactly
what a hard kill skips.
-}
module HostBootstrap.Ownership.Shipped (
    -- * The transaction
    ShippedAuthorityPath,
    mkShippedAuthorityPath,
    shippedAuthorityPath,
    ShippedTargetPath,
    mkShippedTargetPath,
    shippedTargetPath,
    ShippedLinkTargetPath,
    mkShippedLinkTargetPath,
    shippedLinkTargetPath,
    ShippedOwnership,
    mkShippedOwnership,
    shippedAuthority,
    shippedRecord,
    shippedTarget,
    shippedAct,
    ShippedAct (..),
    encodeShippedOwnership,
    decodeShippedOwnership,

    -- * The outcome
    ShippedOutcome (..),
    encodeShippedOutcome,
    decodeShippedOutcome,

    -- * The near side
    ShippedFailure (..),
    classifyShippedOutcome,
    shipOwnedTransaction,

    -- * The far side
    interpretShippedOwnership,
    runShippedOwnership,

    -- * A local directory's live ownership extent
    ShippedDirectoryLease,
    withShippedDirectoryLease,
    useShippedDirectoryLease,
)
where

#ifndef mingw32_HOST_OS
import Control.Exception (IOException, displayException, try)
#endif
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (GeneralCategory (Surrogate), generalCategory)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word32, Word8)
import HostBootstrap.Handoff.Transaction (withFrameChildTransaction)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lift (LiftContext, SelfRef)
import HostBootstrap.Ownership.Clause (Bound, enteredEvidence)
import HostBootstrap.Ownership.Object (
    storeFault,
    ConflictReport (ConflictReport, conflictExpected, conflictObserved, conflictSubject),
    ObjectIdentity,
    ObjectKind (OwnedDirectory, OwnedFile, ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OriginRecord,
    OwnerClaim,
    OwnershipFault (
        OwnershipConflict,
        OwnershipMalformed,
        OwnershipOccupied,
        OwnershipProbeFailed,
        OwnershipUnsupported
    ),
    Payload,
    mkObjectIdentity,
    mkOwnerClaim,
    mkPayload,
    objectIdentityBytes,
    originRecordBinding,
    originRecordKind,
    originRecordOrigin,
    ownershipFault,
    payloadBytes,
    payloadDigest,
 )
import HostBootstrap.Ownership.Primitive (
    OwnershipRow,
    bindOwnedIdentity,
    bindReportedIdentity,
    createOwnedDirectory,
    enterOwnedObject,
    enterReportedObject,
    publishOwnedFile,
    recordOwnedOrigin,
    recordReportedOrigin,
    reenterStoredOwnedObject,
    releaseOwnedObject,
    releaseReportedObject,
    reobserveOwnedIdentity,
    reobserveReportedIdentity,
#ifndef mingw32_HOST_OS
    rowObserveIdentity,
    rowSyncParent,
    withOwnershipRow,
#endif
 )
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Ownership.Tape (
    RecordSubject (RecordSubject, subjectBinding, subjectRecord),
    RecordTape,
    forgetRecord,
    publishBoundRecord,
    publishFreshRecord,
    readRecordUnder,
    readStoredRecordUnder,
    recordTape,
    storedOriginRecord,
 )
import HostBootstrap.Protected (
    ProtectedSession,
    RecordKey,
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
    recordKeyText,
    withProtectedEntry,
 )
import HostBootstrap.Wire.LittleEndian (word32LE)
import qualified System.FilePath as HostPath
import qualified System.FilePath.Posix as PosixPath
import qualified System.FilePath.Windows as WindowsPath
#ifndef mingw32_HOST_OS
import System.IO.Error (isAlreadyExistsError)
#ifdef darwin_HOST_OS
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
#else
import System.Posix.Files (createLink)
#endif
import System.Posix.Files
    ( createSymbolicLink
    , getSymbolicLinkStatus
    , isSymbolicLink
    , readSymbolicLink
    , removeLink
    )
#endif

-- ---------------------------------------------------------------------------
-- The transaction

-- | An absolute authority root addressed in the owning frame's path grammar.
newtype ShippedAuthorityPath = ShippedAuthorityPath FilePath
    deriving (Eq, Show)

{- | Admit scalar path text without choosing a frame on the caller's behalf.

A guest uses POSIX grammar; an empty context can address a Windows outer host.
The receiving process checks its own grammar again before opening the store.
-}
mkShippedAuthorityPath :: FilePath -> Either OwnershipFault ShippedAuthorityPath
mkShippedAuthorityPath path = ShippedAuthorityPath <$> admitShippedPath "authority" path

admitShippedPath :: Text -> FilePath -> Either OwnershipFault FilePath
admitShippedPath role path
    | null path = malformed "must not be empty"
    | '\0' `elem` path = malformed "must not contain NUL"
    | any ((== Surrogate) . generalCategory) path =
        malformed "must be Unicode scalar text"
    | not (PosixPath.isAbsolute path || WindowsPath.isAbsolute path) =
        malformed "must be absolute in its owning frame"
    | otherwise = Right path
  where
    malformed reason = Left (OwnershipMalformed ("the " <> role <> " path " <> reason))

-- | The admitted path text, for encoding and the receiving host's store API.
shippedAuthorityPath :: ShippedAuthorityPath -> FilePath
shippedAuthorityPath (ShippedAuthorityPath path) = path

-- | The object path, distinct from the root that stores its ownership record.
newtype ShippedTargetPath = ShippedTargetPath FilePath
    deriving (Eq, Show)

-- | Admit an absolute scalar object path in the addressed frame's grammar.
mkShippedTargetPath :: FilePath -> Either OwnershipFault ShippedTargetPath
mkShippedTargetPath path = ShippedTargetPath <$> admitShippedPath "object target" path

shippedTargetPath :: ShippedTargetPath -> FilePath
shippedTargetPath (ShippedTargetPath path) = path

-- | A symbolic link's destination, distinct from its object and authority.
newtype ShippedLinkTargetPath = ShippedLinkTargetPath FilePath
    deriving (Eq, Show)

-- | Admit absolute scalar destination text in the addressed frame's grammar.
mkShippedLinkTargetPath :: FilePath -> Either OwnershipFault ShippedLinkTargetPath
mkShippedLinkTargetPath path = ShippedLinkTargetPath <$> admitShippedPath "symbolic link target" path

shippedLinkTargetPath :: ShippedLinkTargetPath -> FilePath
shippedLinkTargetPath (ShippedLinkTargetPath path) = path

{- | One complete ownership transaction, addressed to the frame that owns the
object.

The admitted authority root, durable record, target object and closed act travel
together. A caller cannot replace either path role with an unchecked FilePath.
-}
data ShippedOwnership = ShippedOwnership ShippedAuthorityPath RecordKey ShippedTargetPath ShippedAct
    deriving (Eq, Show)

-- | Address one transaction to an admitted authority root.
mkShippedOwnership :: ShippedAuthorityPath -> RecordKey -> ShippedTargetPath -> ShippedAct -> ShippedOwnership
mkShippedOwnership = ShippedOwnership

shippedAuthority :: ShippedOwnership -> ShippedAuthorityPath
shippedAuthority (ShippedOwnership authority _ _ _) = authority

shippedRecord :: ShippedOwnership -> RecordKey
shippedRecord (ShippedOwnership _ key _ _) = key

shippedTarget :: ShippedOwnership -> ShippedTargetPath
shippedTarget (ShippedOwnership _ _ target _) = target

shippedAct :: ShippedOwnership -> ShippedAct
shippedAct (ShippedOwnership _ _ _ act) = act

{- | The closed set of acts a shipped transaction may name.

Six, because they are the four generic object acts plus symbolic-link take and
give-back for the guest-alias owner. There is no act that runs a command,
because a described command travels through the one interpreter (§ KK) and an
act that could run a string would make this a shell again.
-}
data ShippedAct
    = -- | Report without recording; opening an absent authority store creates its
      -- directories and identity file.
      ShipObserveObject
    | -- | clauses 1–3 over a directory this transaction creates
      ShipTakeDirectory
    | -- | clauses 1–3 over a file this transaction publishes
      ShipTakeFile Payload
    | -- | clause 4, re-entered from the durable record the far side holds
      ShipGiveBackObject
    | -- | clauses 1–3 over a symbolic link published without replacement
      ShipTakeSymbolicLink ShippedLinkTargetPath
    | -- | clause 4 over that symbolic link and its exact target
      ShipGiveBackSymbolicLink ShippedLinkTargetPath
    deriving (Eq, Show)

linkTargetOf :: ShippedAct -> Maybe ShippedLinkTargetPath
linkTargetOf ShipObserveObject = Nothing
linkTargetOf ShipTakeDirectory = Nothing
linkTargetOf (ShipTakeFile _) = Nothing
linkTargetOf ShipGiveBackObject = Nothing
linkTargetOf (ShipTakeSymbolicLink target) = Just target
linkTargetOf (ShipGiveBackSymbolicLink target) = Just target

-- ---------------------------------------------------------------------------
-- The outcome

{- | What the frame that owns the object answered.

A refusal is a value rather than a closed pipe, so a caller learns that the far
side declined and why, in the same closed fault vocabulary a local row speaks.
-}
data ShippedOutcome
    = -- | the observation found nothing
      ShippedObjectAbsent
    | -- | the observation found this object
      ShippedObjectPresent ObjectIdentity
    | -- | the object is owned, and this is the identity bound to its record
      ShippedObjectTaken ObjectIdentity
    | -- | the object is gone and its record is forgotten
      ShippedObjectGivenBack
    | -- | this transaction published and bound a symbolic link
      ShippedSymbolicLinkCreated ObjectIdentity
    | -- | an interrupted or exact retry retained the bound symbolic link
      ShippedSymbolicLinkRetained ObjectIdentity
    | -- | the far frame refused, in the seam's own vocabulary
      ShippedRefused OwnershipFault
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- The near side

-- | Which stage prevented the caller from receiving a successful outcome.
data ShippedFailure
    = -- | the frame transaction could not return an answer
      ShippedCrossingFailed Text
    | -- | an answer arrived but its ownership outcome could not be decoded
      ShippedOutcomeUndecodable Text
    | -- | the frame decoded the transaction and refused its requested act
      ShippedFrameRefused OwnershipFault
    deriving (Eq, Show)

-- | Preserve transport, decoding and frame refusal as distinct returned values.
classifyShippedOutcome :: Either Text ByteString -> Either ShippedFailure ShippedOutcome
classifyShippedOutcome crossed = case crossed of
    Left failure -> Left (ShippedCrossingFailed failure)
    Right raw -> case decodeShippedOutcome raw of
        Left fault -> Left (ShippedOutcomeUndecodable (Text.pack (show fault)))
        Right (ShippedRefused fault) -> Left (ShippedFrameRefused fault)
        Right outcome -> Right outcome

{- | Run one ownership transaction at the frame @context@ names.

The invocation comes from the lift's one fold and the process group is ended on
every exit path, because both belong to the crossing this call is wrapped in.
The transaction is encoded here and its returned outcome is classified here.
A crossing failure retains its transport diagnostic, an undecodable answer
retains its decoding diagnostic, and a decoded frame refusal retains the
frame's OwnershipFault. These are three distinct ShippedFailure constructors.
-}
shipOwnedTransaction ::
    HostConfig ->
    SelfRef ->
    LiftContext ->
    ShippedOwnership ->
    IO (Either ShippedFailure ShippedOutcome)
shipOwnedTransaction config self context transaction =
    classifyShippedOutcome
        <$> withFrameChildTransaction
            config
            self
            context
            (encodeShippedOwnership transaction)

-- ---------------------------------------------------------------------------
-- The far side

{- | Interpret one shipped ownership transaction, as the frame that owns the
object.

The signature is the crossing's own — opaque bytes in, opaque bytes out — so the
transport stays uninterpreted and this module stays the only place the bytes
mean anything. A transaction this frame cannot read is answered with an encoded
refusal rather than with a protocol failure, because a caller that reads a
refusal knows its frame declined while a caller that reads a broken frame knows
only that something ended.
-}
interpretShippedOwnership :: ByteString -> IO (Either Text ByteString)
interpretShippedOwnership raw = case decodeShippedOwnership raw of
    Left fault -> pure (Right (encodeShippedOutcome (ShippedRefused fault)))
    Right transaction -> do
        outcome <- runShippedOwnership ownershipRowForHost transaction
        pure (Right (encodeShippedOutcome outcome))

{- | Perform one shipped transaction against a row, in this process.

Clause 1 is the protected store's exclusive entry, taken here and released by
the kernel when this process ends; clause 2 is that store's compare-and-swap.
Both are the same two every host-local owner holds, so a shipped transaction is
not a second way to own something — it is the same way, run somewhere else.
-}
runShippedOwnership :: OwnershipRow -> ShippedOwnership -> IO ShippedOutcome
runShippedOwnership row transaction =
    either ShippedRefused id
        <$> withShippedEntry transaction (\session -> Right <$> inEntry row transaction session)

-- | The same receiving-frame validation and entry surround both local uses.
withShippedEntry ::
    ShippedOwnership ->
    (forall session. ProtectedSession session -> IO (Either OwnershipFault result)) ->
    IO (Either OwnershipFault result)
withShippedEntry transaction action
    | not (HostPath.isAbsolute authority) =
        pure (Left (OwnershipMalformed "the authority path is not absolute in the receiving frame"))
    | not (HostPath.isAbsolute target) =
        pure (Left (OwnershipMalformed "the object target path is not absolute in the receiving frame"))
    | maybe False (not . HostPath.isAbsolute . shippedLinkTargetPath) (linkTargetOf (shippedAct transaction)) =
        pure (Left (OwnershipMalformed "the symbolic link target is not absolute in the receiving frame"))
    | otherwise = do
        opened <- openProtectedStore authority
        case opened of
            Left failure -> pure (Left (storeFault "open this frame's ownership authority" failure))
            Right store -> do
                entered <- withProtectedEntry store (\session -> Right <$> action session)
                pure (either (Left . storeFault "enter this frame's ownership authority") id entered)
  where
    authority = shippedAuthorityPath (shippedAuthority transaction)
    target = shippedTargetPath (shippedTarget transaction)

{- | A directory bound under the protected entry that encloses its consumer.

The entry and object indices are existential inside a fresh nominal lease. Its
constructor and fields are private; the only effect-bearing eliminator checks
the actual entry and directory again, including after its action returns.
-}
data ShippedDirectoryLease lease
    = forall session object.
      ShippedDirectoryLease
        { directoryLeaseRow :: OwnershipRow
        , directoryLeaseBound :: Bound session object
        }

type role ShippedDirectoryLease nominal

{- | Acquire a directory through the ordinary shipped take, then keep its entry.

The same acquisition resolves fresh, retained and interrupted records. Re-entry
reads the bound record from this entry's protected tape; an in-memory identity
alone never produces a lease. A callback exception releases the entry through
the protected store's existing bracket.
-}
withShippedDirectoryLease ::
    OwnershipRow ->
    ShippedOwnership ->
    (forall lease. ShippedDirectoryLease lease -> IO result) ->
    IO (Either OwnershipFault result)
withShippedDirectoryLease row transaction consume
    | shippedAct transaction /= ShipTakeDirectory =
        pure (Left (OwnershipMalformed "a directory lease requires a directory-take transaction"))
    | otherwise =
        withShippedEntry transaction $ \session -> do
            taken <- inEntry row transaction session
            case taken of
                ShippedRefused fault -> pure (Left fault)
                ShippedObjectTaken identity -> do
                    current <- readStoredRecordUnder (shippedTape session) (shippedRecord transaction)
                    case current of
                        Left fault -> pure (Left fault)
                        Right (Just stored)
                            | let record = storedOriginRecord stored
                            , originRecordKind record == OwnedDirectory
                            , originRecordOrigin record == OriginAbsent
                            , originRecordBinding record == Just identity ->
                                reenterStoredOwnedObject row session target stored $ \bound ->
                                    let lease = ShippedDirectoryLease row bound
                                     in useShippedDirectoryLease lease (consume lease)
                        _ -> pure (Left (OwnershipMalformed "the acquired directory has no matching bound record"))
                _ -> pure (Left (OwnershipMalformed "directory acquisition returned a non-directory outcome"))
  where
    target = shippedTargetPath (shippedTarget transaction)

{- | Run an action only under this thread's live entry and exact directory.

The protected session checks its owner thread and liveness before the kernel
identity observation. An escaped closure, or a use from another thread, refuses
before running its action. The callback's surrounding entry stays held through
both observations and the action.
-}
useShippedDirectoryLease :: ShippedDirectoryLease lease -> IO result -> IO (Either OwnershipFault result)
useShippedDirectoryLease ShippedDirectoryLease{directoryLeaseRow = row, directoryLeaseBound = bound} action = do
    before <- reobserveOwnedIdentity row bound
    case before of
        Left fault -> pure (Left fault)
        Right _ -> do
            result <- action
            after <- reobserveOwnedIdentity row bound
            pure (result <$ after)

inEntry ::
    OwnershipRow ->
    ShippedOwnership ->
    ProtectedSession session ->
    IO ShippedOutcome
inEntry row transaction session = case shippedAct transaction of
    ShipObserveObject -> observe
    ShipTakeDirectory -> takeObject OwnedDirectory Nothing
    ShipTakeFile payload -> takeObject (OwnedFile (payloadDigest payload)) (Just payload)
    ShipGiveBackObject -> giveBack
    ShipTakeSymbolicLink linkTarget -> takeSymbolicLink (shippedLinkTargetPath linkTarget)
    ShipGiveBackSymbolicLink linkTarget -> giveBackSymbolicLink (shippedLinkTargetPath linkTarget)
  where
    key = shippedRecord transaction
    target = shippedTargetPath (shippedTarget transaction)
    settle = either ShippedRefused id

    observe = do
        outcome <- enterOwnedObject row session target $ \entered ->
            enteredEvidence
                ( \_target origin ->
                    pure
                        ( Right
                            ( case origin of
                                OriginAbsent -> ShippedObjectAbsent
                                OriginPresent identity -> ShippedObjectPresent identity
                            )
                        )
                )
                entered
        pure (settle outcome)

    -- An exact retry converges on the record this frame already holds rather
    -- than opening a second transaction over the same object.
    takeObject kind payload = do
        stored <- readStoredRecordUnder (shippedTape session) key
        case stored of
            Left fault -> pure (ShippedRefused fault)
            Right (Just record) -> retried kind record
            Right Nothing -> do
                outcome <- enterOwnedObject row session target $ \entered ->
                    enteredEvidence
                        ( \_target origin -> case origin of
                            OriginPresent _ -> pure (Left (occupied target))
                            OriginAbsent -> createUnder entered kind payload
                        )
                        entered
                pure (settle outcome)

    retried kind stored
        | originRecordKind record /= kind =
            pure (ShippedRefused (OwnershipMalformed "this frame's record describes a different object kind or file payload"))
        | originRecordOrigin record /= OriginAbsent =
            pure (ShippedRefused (OwnershipMalformed "this frame's record did not record an absent origin"))
        | otherwise = case originRecordBinding record of
            Just identity -> do
                outcome <- reenterStoredOwnedObject row session target stored $ \bound ->
                    fmap
                        (fmap (const (ShippedObjectTaken identity)))
                        (reobserveOwnedIdentity row bound)
                pure (settle outcome)
            Nothing
                | kind == OwnedDirectory -> resumeUnboundDirectory record
                | otherwise ->
                    pure
                        ( ShippedRefused
                            ( OwnershipMalformed
                                "this frame holds an unbound record for the object, so a previous transaction did not get past clause 2"
                            )
                        )
      where
        record = storedOriginRecord stored

    createUnder entered kind payload = do
        recorded <- recordOwnedOrigin row entered kind (publishOrigin session key)
        case recorded of
            Left fault -> pure (Left fault)
            Right token -> do
                created <- case payload of
                    Nothing -> createOwnedDirectory row token
                    Just bytes -> publishOwnedFile row token bytes (stagingOf transaction)
                case created of
                    Left fault -> pure (Left fault)
                    Right identity -> do
                        bound <- bindOwnedIdentity row token identity (publishBinding session key)
                        pure (fmap (const (ShippedObjectTaken identity)) bound)

    -- Both directions resolve the same interrupted directory record under the
    -- protected entry. Exact unbound publication is already idempotent.
    resumeUnboundDirectory record
        | originRecordOrigin record /= OriginAbsent =
            pure (ShippedRefused (OwnershipMalformed "this frame's directory record did not record an absent origin"))
        | otherwise = do
            outcome <- enterOwnedObject row session target $ \entered ->
                enteredEvidence
                    ( \_target origin -> case origin of
                        OriginAbsent
                            | shippedAct transaction == ShipTakeDirectory ->
                                createUnder entered OwnedDirectory Nothing
                            | otherwise ->
                                fmap (fmap (const ShippedObjectGivenBack)) (forget session key record)
                        OriginPresent identity ->
                            pure
                                ( Left
                                    ( OwnershipConflict
                                        ConflictReport
                                            { conflictSubject =
                                                Text.pack target
                                                    <> " exists without a recorded identity; inspect it and restore the recorded absence before retrying"
                                            , conflictExpected = OriginAbsent
                                            , conflictObserved = OriginPresent identity
                                            }
                                    )
                                )
                    )
                    entered
            pure (settle outcome)

    giveBack = do
        stored <- readStoredRecordUnder (shippedTape session) key
        case stored of
            Left fault -> pure (ShippedRefused fault)
            Right Nothing -> pure ShippedObjectGivenBack
            Right (Just record)
                | let held = storedOriginRecord record
                , originRecordKind held == OwnedDirectory
                , originRecordBinding held == Nothing ->
                    resumeUnboundDirectory held
                | otherwise -> do
                    outcome <- reenterStoredOwnedObject row session target record $ \bound -> do
                        releasable <- reobserveOwnedIdentity row bound
                        case releasable of
                            Left fault -> pure (Left fault)
                            Right token ->
                                fmap
                                    (fmap (const ShippedObjectGivenBack))
                                    (releaseOwnedObject row token (forget session key))
                    pure (settle outcome)

    takeSymbolicLink linkTarget = do
        stored <- readBoundRecord session key
        case stored of
            Left fault -> pure (ShippedRefused fault)
            Right (Just record) -> resumeSymbolicLink linkTarget record
            Right Nothing -> do
                observed <- observeSymbolicLink target linkTarget
                case observed of
                    Left fault -> pure (ShippedRefused fault)
                    Right (SymbolicLinkAbsent) -> beginSymbolicLink linkTarget
                    Right present -> pure (ShippedRefused (symbolicLinkOccupied target present))

    beginSymbolicLink linkTarget = do
        outcome <-
            enterReportedObject session target OriginAbsent $ \entered -> do
                recorded <-
                    recordReportedOrigin
                        entered
                        (symbolicLinkClaim linkTarget)
                        (publishOrigin session key)
                case recorded of
                    Left fault -> pure (Left fault)
                    Right token -> publishSymbolicLink linkTarget token ShippedSymbolicLinkCreated
        pure (settle outcome)

    resumeSymbolicLink linkTarget record =
        case validateSymbolicLinkRecord linkTarget record of
            Left fault -> pure (ShippedRefused fault)
            Right (Just identity) -> do
                observed <- observeSymbolicLink target linkTarget
                case observed of
                    Left fault -> pure (ShippedRefused fault)
                    Right (SymbolicLinkExact current)
                        | current == identity -> do
                            cleaned <- cleanupSymbolicLinkStage row transaction linkTarget identity
                            pure (either ShippedRefused (const (ShippedSymbolicLinkRetained identity)) cleaned)
                    Right SymbolicLinkAbsent -> do
                        published <- publishPreparedSymbolicLink row transaction linkTarget identity
                        case published of
                            Left fault -> pure (ShippedRefused fault)
                            Right () -> do
                                cleaned <- cleanupSymbolicLinkStage row transaction linkTarget identity
                                pure (either ShippedRefused (const (ShippedSymbolicLinkRetained identity)) cleaned)
                    Right present -> pure (ShippedRefused (symbolicLinkIdentityConflict target identity present))
            Right Nothing -> do
                outcome <-
                    enterReportedObject session target OriginAbsent $ \entered -> do
                        recorded <-
                            recordReportedOrigin
                                entered
                                (symbolicLinkClaim linkTarget)
                                (publishExactRecord session key record)
                        case recorded of
                            Left fault -> pure (Left fault)
                            Right token -> publishSymbolicLink linkTarget token ShippedSymbolicLinkRetained
                pure (settle outcome)

    publishSymbolicLink linkTarget recorded answer = do
        prepared <- prepareSymbolicLink row transaction linkTarget
        case prepared of
            Left fault -> pure (Left fault)
            Right identity -> do
                bound <- bindReportedIdentity recorded identity (publishBinding session key)
                case bound of
                    Left fault -> pure (Left fault)
                    Right _ -> do
                        published <- publishPreparedSymbolicLink row transaction linkTarget identity
                        case published of
                            Left fault -> pure (Left fault)
                            Right () -> do
                                cleaned <- cleanupSymbolicLinkStage row transaction linkTarget identity
                                pure (fmap (const (answer identity)) cleaned)

    giveBackSymbolicLink linkTarget = do
        stored <- readBoundRecord session key
        case stored of
            Left fault -> pure (ShippedRefused fault)
            Right Nothing -> do
                observed <- observeSymbolicLink target linkTarget
                pure $ case observed of
                    Left fault -> ShippedRefused fault
                    Right SymbolicLinkAbsent -> ShippedObjectGivenBack
                    Right present -> ShippedRefused (symbolicLinkOccupied target present)
            Right (Just record) ->
                case validateSymbolicLinkRecord linkTarget record of
                    Left fault -> pure (ShippedRefused fault)
                    Right Nothing -> releaseUnboundSymbolicLink linkTarget record
                    Right (Just identity) -> releaseSymbolicLink linkTarget record identity

    releaseUnboundSymbolicLink linkTarget record = do
        observed <- observeSymbolicLink target linkTarget
        case observed of
            Left fault -> pure (ShippedRefused fault)
            Right SymbolicLinkAbsent -> do
                cleaned <- cleanupUnboundSymbolicLinkStage row transaction linkTarget
                case cleaned of
                    Left fault -> pure (ShippedRefused fault)
                    Right () -> do
                        forgotten <- forget session key record
                        pure (either ShippedRefused (const ShippedObjectGivenBack) forgotten)
            Right present -> pure (ShippedRefused (symbolicLinkOriginConflict target OriginAbsent present))

    releaseSymbolicLink linkTarget record identity = do
        observed <- observeSymbolicLink target linkTarget
        case observed of
            Left fault -> pure (ShippedRefused fault)
            Right SymbolicLinkAbsent -> do
                cleaned <- cleanupSymbolicLinkStage row transaction linkTarget identity
                case cleaned of
                    Left fault -> pure (ShippedRefused fault)
                    Right () -> do
                        forgotten <- forget session key record
                        pure (either ShippedRefused (const ShippedObjectGivenBack) forgotten)
            Right (SymbolicLinkExact current)
                | current == identity -> do
                    cleaned <- cleanupSymbolicLinkStage row transaction linkTarget identity
                    case cleaned of
                        Left fault -> pure (ShippedRefused fault)
                        Right () -> releaseExactSymbolicLink linkTarget record identity
            Right present -> pure (ShippedRefused (symbolicLinkIdentityConflict target identity present))

    releaseExactSymbolicLink linkTarget record identity = do
        outcome <-
            enterReportedObject session target OriginAbsent $ \entered -> do
                recorded <-
                    recordReportedOrigin
                        entered
                        (symbolicLinkClaim linkTarget)
                        (publishExactRecord session key record)
                case recorded of
                    Left fault -> pure (Left fault)
                    Right token -> do
                        rebound <- bindReportedIdentity token identity (publishExactRecord session key record)
                        case rebound of
                            Left fault -> pure (Left fault)
                            Right bound -> do
                                removed <-
                                    removeExactSymbolicLink row target linkTarget identity
                                        (reobserveReportedIdentity bound . OriginPresent)
                                case removed of
                                    Left fault -> pure (Left fault)
                                    Right releasable ->
                                        releaseReportedObject releasable OriginAbsent (forget session key)
        pure (either ShippedRefused (const ShippedObjectGivenBack) outcome)

occupied :: FilePath -> OwnershipFault
occupied target =
    OwnershipOccupied
        ( Text.pack target
            <> " is already there, and this transaction adopts nothing it finds"
        )

{- | Where a shipped file's payload is written before it is published.

Beside the target and derived from the record key, which names this object and
nothing else, so two transactions never stage through one name.
-}
stagingOf :: ShippedOwnership -> FilePath
stagingOf transaction =
    shippedTargetPath (shippedTarget transaction)
        <> ".hostbootstrap-shipped-"
        <> Text.unpack (recordKeyText (shippedRecord transaction))

data SymbolicLinkObservation
    = SymbolicLinkAbsent
    | SymbolicLinkExact ObjectIdentity
    | SymbolicLinkOther (Maybe ObjectIdentity)

symbolicLinkClaim :: FilePath -> OwnerClaim
symbolicLinkClaim = mkOwnerClaim . TextEncoding.encodeUtf8 . Text.pack

validateSymbolicLinkRecord :: FilePath -> OriginRecord -> Either OwnershipFault (Maybe ObjectIdentity)
validateSymbolicLinkRecord linkTarget record
    | originRecordKind record /= ReportedObject (symbolicLinkClaim linkTarget) =
        Left (OwnershipMalformed "the symbolic-link record belongs to a different target claim")
    | originRecordOrigin record /= OriginAbsent =
        Left (OwnershipMalformed "the symbolic-link record did not record an absent origin")
    | otherwise = Right (originRecordBinding record)

symbolicLinkOccupied :: FilePath -> SymbolicLinkObservation -> OwnershipFault
symbolicLinkOccupied path observation =
    OwnershipOccupied
        (Text.pack path <> " is occupied by " <> symbolicLinkObservationText observation)

symbolicLinkIdentityConflict :: FilePath -> ObjectIdentity -> SymbolicLinkObservation -> OwnershipFault
symbolicLinkIdentityConflict path expected =
    symbolicLinkOriginConflict path (OriginPresent expected)

symbolicLinkOriginConflict :: FilePath -> Origin -> SymbolicLinkObservation -> OwnershipFault
symbolicLinkOriginConflict path expected observation =
    OwnershipConflict
        ConflictReport
            { conflictSubject = Text.pack path
            , conflictExpected = expected
            , conflictObserved = case observation of
                SymbolicLinkAbsent -> OriginAbsent
                SymbolicLinkExact identity -> OriginPresent identity
                SymbolicLinkOther (Just identity) -> OriginPresent identity
                SymbolicLinkOther Nothing -> OriginAbsent
            }

symbolicLinkObservationText :: SymbolicLinkObservation -> Text
symbolicLinkObservationText SymbolicLinkAbsent = "an absent path"
symbolicLinkObservationText (SymbolicLinkExact _) = "an unmanaged exact-looking symbolic link"
symbolicLinkObservationText (SymbolicLinkOther _) = "a different filesystem object"

publishExactRecord ::
    ProtectedSession session ->
    RecordKey ->
    OriginRecord ->
    OriginRecord ->
    IO (Either OwnershipFault ())
publishExactRecord session key expected proposed = do
    stored <- readBoundRecord session key
    pure $ case stored of
        Left fault -> Left fault
        Right Nothing -> Left (OwnershipMalformed "the symbolic-link ownership record vanished during retry")
        Right (Just held)
            | held == expected
            , originRecordKind expected == originRecordKind proposed
            , originRecordOrigin expected == originRecordOrigin proposed ->
                Right ()
            | otherwise -> Left (OwnershipMalformed "the symbolic-link retry reconstructed a different ownership record")

observeSymbolicLink :: FilePath -> FilePath -> IO (Either OwnershipFault SymbolicLinkObservation)
#ifdef mingw32_HOST_OS
observeSymbolicLink _path _linkTarget =
    pure (Left (OwnershipUnsupported "symbolic-link ownership is available only in a POSIX frame"))
#else
observeSymbolicLink path linkTarget = do
    before <- observeIdentity
    case before of
        Left fault -> pure (Left fault)
        Right Nothing -> pure (Right SymbolicLinkAbsent)
        Right (Just stable) -> do
            statusResult <- try (getSymbolicLinkStatus path)
            case statusResult of
                Left failure -> pure (Left (symbolicLinkProbe "observe" path failure))
                Right status -> do
                    classified <-
                        if not (isSymbolicLink status)
                            then pure (Right (SymbolicLinkOther (Just stable)))
                            else do
                                targetResult <- try (readSymbolicLink path)
                                pure $ case targetResult of
                                    Left failure -> Left (symbolicLinkProbe "read" path failure)
                                    Right actual
                                        | actual == linkTarget -> Right (SymbolicLinkExact stable)
                                        | otherwise -> Right (SymbolicLinkOther (Just stable))
                    after <- observeIdentity
                    pure $ do
                        current <- after
                        if current == Just stable
                            then classified
                            else Left (OwnershipOccupied (Text.pack path <> " changed during symbolic-link observation"))
  where
    observeIdentity =
        withOwnershipRow ownershipRowForHost (\primitives -> rowObserveIdentity primitives path)
#endif

prepareSymbolicLink :: OwnershipRow -> ShippedOwnership -> FilePath -> IO (Either OwnershipFault ObjectIdentity)
#ifdef mingw32_HOST_OS
prepareSymbolicLink _row _transaction _linkTarget =
    pure (Left (OwnershipUnsupported "symbolic-link ownership is available only in a POSIX frame"))
#else
prepareSymbolicLink row transaction linkTarget = do
    let stage = stagingOf transaction
    stageObserved <- observeSymbolicLink stage linkTarget
    case stageObserved of
        Left fault -> pure (Left fault)
        Right SymbolicLinkAbsent -> do
            created <- try (createSymbolicLink linkTarget stage)
            case created of
                Left failure -> pure (Left (symbolicLinkProbe "create staging" stage failure))
                Right () -> do
                    synced <- syncSymbolicLinkParent row stage
                    case synced of
                        Left fault -> pure (Left fault)
                        Right () -> do
                            observed <- observeSymbolicLink stage linkTarget
                            pure $ case observed of
                                Right (SymbolicLinkExact identity) -> Right identity
                                Right other -> Left (symbolicLinkOccupied stage other)
                                Left fault -> Left fault
        Right (SymbolicLinkExact identity) -> pure (Right identity)
        Right other -> pure (Left (symbolicLinkOccupied stage other))
#endif

publishPreparedSymbolicLink :: OwnershipRow -> ShippedOwnership -> FilePath -> ObjectIdentity -> IO (Either OwnershipFault ())
#ifdef mingw32_HOST_OS
publishPreparedSymbolicLink _row _transaction _linkTarget _identity =
    pure (Left (OwnershipUnsupported "symbolic-link ownership is available only in a POSIX frame"))
#else
publishPreparedSymbolicLink row transaction linkTarget expectedIdentity = do
    let stage = stagingOf transaction
        target = shippedTargetPath (shippedTarget transaction)
    staged <- observeSymbolicLink stage linkTarget
    case staged of
        Right (SymbolicLinkExact stagedIdentity)
            | stagedIdentity == expectedIdentity -> do
                published <- try (publishSymbolicLinkNoReplace stage target)
                case published of
                    Left failure
                        | isAlreadyExistsError failure -> confirmPublished target
                        | otherwise -> pure (Left (symbolicLinkProbe "publish" target failure))
                    Right () -> do
                        synced <- syncSymbolicLinkParent row target
                        either (pure . Left) (const (confirmPublished target)) synced
        Right other -> pure (Left (symbolicLinkIdentityConflict stage expectedIdentity other))
        Left fault -> pure (Left fault)
  where
    confirmPublished target = do
        observed <- observeSymbolicLink target linkTarget
        pure $ case observed of
            Right (SymbolicLinkExact identity)
                | identity == expectedIdentity -> Right ()
            Right other -> Left (symbolicLinkIdentityConflict target expectedIdentity other)
            Left fault -> Left fault
#endif

-- | Publish the already-bound staging link without replacing an existing name.
-- Linux can give the symlink inode a second name with @link(2)@. Darwin/APFS
-- deliberately refuses that operation for symbolic links, so its equivalent
-- is @renamex_np(RENAME_EXCL)@; the durable record already binds the staging
-- inode before this move, which makes both crash windows recoverable.
#ifndef mingw32_HOST_OS
publishSymbolicLinkNoReplace :: FilePath -> FilePath -> IO ()
#if defined(darwin_HOST_OS)
publishSymbolicLinkNoReplace source target =
    withCString source $ \sourcePath ->
        withCString target $ \targetPath ->
            throwErrnoIfMinus1_ "renamex_np(RENAME_EXCL)" (c_renamex_np sourcePath targetPath renameExclusive)
  where
    renameExclusive = 0x00000004
#else
publishSymbolicLinkNoReplace = createLink
#endif
#endif

#ifdef darwin_HOST_OS
foreign import capi unsafe "stdio.h renamex_np"
    c_renamex_np :: CString -> CString -> CUInt -> IO CInt
#endif

-- | Withdraw the recorded staging identity during take recovery and give-back.
-- Synchronize its parent even when the name is absent, before forgetting.
cleanupSymbolicLinkStage :: OwnershipRow -> ShippedOwnership -> FilePath -> ObjectIdentity -> IO (Either OwnershipFault ())
#ifdef mingw32_HOST_OS
cleanupSymbolicLinkStage _row _transaction _linkTarget _identity =
    pure (Left (OwnershipUnsupported "symbolic-link ownership is available only in a POSIX frame"))
#else
cleanupSymbolicLinkStage row transaction linkTarget identity = do
    let stage = stagingOf transaction
    observed <- observeSymbolicLink stage linkTarget
    case observed of
        Left fault -> pure (Left fault)
        Right SymbolicLinkAbsent -> syncSymbolicLinkParent row stage
        Right (SymbolicLinkExact current)
            | current == identity -> removeExactSymbolicLink row stage linkTarget identity (const (Right ()))
        Right other -> pure (Left (symbolicLinkIdentityConflict stage identity other))
#endif

-- | An unbound intent owns only an exact staging link, never an alias occupant.
cleanupUnboundSymbolicLinkStage :: OwnershipRow -> ShippedOwnership -> FilePath -> IO (Either OwnershipFault ())
cleanupUnboundSymbolicLinkStage row transaction linkTarget = do
    let stage = stagingOf transaction
    observed <- observeSymbolicLink stage linkTarget
    case observed of
        Left fault -> pure (Left fault)
        Right SymbolicLinkAbsent -> pure (Right ())
        Right (SymbolicLinkExact identity) ->
            removeExactSymbolicLink row stage linkTarget identity (const (Right ()))
        Right other -> pure (Left (symbolicLinkOccupied stage other))

-- | Apply the pure identity admission to the fresh sample before unlinking.
-- The returned evidence is the evidence admitted from that same observation.
removeExactSymbolicLink ::
    OwnershipRow ->
    FilePath ->
    FilePath ->
    ObjectIdentity ->
    (ObjectIdentity -> Either OwnershipFault admitted) ->
    IO (Either OwnershipFault admitted)
#ifdef mingw32_HOST_OS
removeExactSymbolicLink _row _path _linkTarget _identity _admit =
    pure (Left (OwnershipUnsupported "symbolic-link ownership is available only in a POSIX frame"))
#else
removeExactSymbolicLink row path linkTarget identity admit = do
    observed <- observeSymbolicLink path linkTarget
    case observed of
        Left fault -> pure (Left fault)
        Right (SymbolicLinkExact current)
            | current == identity -> case admit current of
                Left fault -> pure (Left fault)
                Right admitted -> do
                    removed <- try (removeLink path)
                    case removed of
                        Left failure -> pure (Left (symbolicLinkProbe "remove" path failure))
                        Right () -> do
                            synced <- syncSymbolicLinkParent row path
                            pure (fmap (const admitted) synced)
        Right other -> pure (Left (symbolicLinkIdentityConflict path identity other))
#endif

#ifndef mingw32_HOST_OS
syncSymbolicLinkParent :: OwnershipRow -> FilePath -> IO (Either OwnershipFault ())
syncSymbolicLinkParent row path =
    withOwnershipRow row (\primitives -> rowSyncParent primitives path)

symbolicLinkProbe :: Text -> FilePath -> IOException -> OwnershipFault
symbolicLinkProbe operation path failure =
    OwnershipProbeFailed
        (operation <> " symbolic link " <> Text.pack path)
        (Text.pack (displayException failure))
#endif

-- ---------------------------------------------------------------------------
-- Clause 2, in the far frame's own store

{- | What this row calls its records, for the shared tape's refusals.

The shipped row owns no richer error sum than the seam's own, so its carrier is
the identity on a clause fault; only the subject is its own.
-}
shippedSubject :: RecordSubject
shippedSubject =
    RecordSubject
        { subjectRecord = "this object's ownership record"
        , subjectBinding = "bind this object's identity"
        }

shippedTape :: ProtectedSession session -> RecordTape session
shippedTape session = recordTape session shippedSubject

readBoundRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either OwnershipFault (Maybe OriginRecord))
readBoundRecord session key = readRecordUnder (shippedTape session) key

publishOrigin ::
    ProtectedSession session ->
    RecordKey ->
    OriginRecord ->
    IO (Either OwnershipFault ())
publishOrigin session key = publishFreshRecord (shippedTape session) key

publishBinding ::
    ProtectedSession session ->
    RecordKey ->
    OriginRecord ->
    IO (Either OwnershipFault ())
publishBinding session key = publishBoundRecord (shippedTape session) key

forget ::
    ProtectedSession session ->
    RecordKey ->
    OriginRecord ->
    IO (Either OwnershipFault ())
forget session key _record = forgetRecord (shippedTape session) key

-- ---------------------------------------------------------------------------
-- The wire

{- | The transaction, exactly.

Paths travel as UTF-8 text and only the payload is arbitrary bytes. Length
framing keeps either kind of field from describing the next field.
-}
encodeShippedOwnership :: ShippedOwnership -> ByteString
encodeShippedOwnership transaction =
    strict
        ( Builder.byteString transactionMagic
            <> Builder.word8 (actTag (shippedAct transaction))
            <> sized (asciiBytes (Text.pack (shippedAuthorityPath (shippedAuthority transaction))))
            <> sized (asciiBytes (recordKeyText (shippedRecord transaction)))
            <> sized (asciiBytes (Text.pack (shippedTargetPath (shippedTarget transaction))))
            <> payloadField (shippedAct transaction)
        )
  where
    payloadField (ShipTakeFile payload) = sized (payloadBytes payload)
    payloadField (ShipTakeSymbolicLink target) = sized (asciiBytes (Text.pack (shippedLinkTargetPath target)))
    payloadField (ShipGiveBackSymbolicLink target) = sized (asciiBytes (Text.pack (shippedLinkTargetPath target)))
    payloadField _ = mempty

decodeShippedOwnership :: ByteString -> Either OwnershipFault ShippedOwnership
decodeShippedOwnership raw = runExact "ownership transaction" raw $ do
    checkMagic transactionMagic "ownership transaction"
    tag <- getWord8
    admittedAuthority <- getAdmittedPath mkShippedAuthorityPath "the ownership transaction's authority"
    rawKey <- getText "the ownership transaction's record key"
    admittedTarget <- getAdmittedPath mkShippedTargetPath "the ownership transaction's target"
    act <- case tag of
        0 -> pure ShipObserveObject
        1 -> pure ShipTakeDirectory
        2 -> ShipTakeFile . mkPayload <$> getSized "the ownership transaction's payload"
        3 -> pure ShipGiveBackObject
        4 -> ShipTakeSymbolicLink <$> getAdmittedPath mkShippedLinkTargetPath "the symbolic link's target"
        5 -> ShipGiveBackSymbolicLink <$> getAdmittedPath mkShippedLinkTargetPath "the symbolic link's target"
        _ -> refuse "the ownership transaction names an unknown act"
    key <- case mkRecordKey rawKey of
        Left failure ->
            refuse
                ( "the ownership transaction's record key is not a record key: "
                    <> protectedErrorMessage failure
                )
        Right key -> pure key
    pure (mkShippedOwnership admittedAuthority key admittedTarget act)

encodeShippedOutcome :: ShippedOutcome -> ByteString
encodeShippedOutcome outcome =
    strict (Builder.byteString outcomeMagic <> body outcome)
  where
    body ShippedObjectAbsent = Builder.word8 0
    body (ShippedObjectPresent identity) =
        Builder.word8 1 <> sized (objectIdentityBytes identity)
    body (ShippedObjectTaken identity) =
        Builder.word8 2 <> sized (objectIdentityBytes identity)
    body ShippedObjectGivenBack = Builder.word8 3
    body (ShippedRefused fault) = Builder.word8 4 <> faultBody fault
    body (ShippedSymbolicLinkCreated identity) =
        Builder.word8 5 <> sized (objectIdentityBytes identity)
    body (ShippedSymbolicLinkRetained identity) =
        Builder.word8 6 <> sized (objectIdentityBytes identity)

decodeShippedOutcome :: ByteString -> Either OwnershipFault ShippedOutcome
decodeShippedOutcome raw = runExact "ownership outcome" raw $ do
    checkMagic outcomeMagic "ownership outcome"
    tag <- getWord8
    case tag of
        0 -> pure ShippedObjectAbsent
        1 -> ShippedObjectPresent <$> getIdentity
        2 -> ShippedObjectTaken <$> getIdentity
        3 -> pure ShippedObjectGivenBack
        4 -> ShippedRefused <$> getFault
        5 -> ShippedSymbolicLinkCreated <$> getIdentity
        6 -> ShippedSymbolicLinkRetained <$> getIdentity
        _ -> refuse "the ownership outcome names an unknown answer"

transactionMagic :: ByteString
transactionMagic = "hb-owned-transaction-1"

outcomeMagic :: ByteString
outcomeMagic = "hb-owned-outcome-1"

actTag :: ShippedAct -> Word8
actTag ShipObserveObject = 0
actTag ShipTakeDirectory = 1
actTag (ShipTakeFile _) = 2
actTag ShipGiveBackObject = 3
actTag (ShipTakeSymbolicLink _) = 4
actTag (ShipGiveBackSymbolicLink _) = 5

{- | The closed fault sum, on the wire.

Through the total eliminator, so a case added to the sum is a compile error here
rather than a fault that crosses a frame as something else.
-}
faultBody :: OwnershipFault -> Builder.Builder
faultBody =
    ownershipFault
        (\reason -> Builder.word8 0 <> sized (asciiBytes reason))
        ( \operation reason ->
            Builder.word8 1 <> sized (asciiBytes operation) <> sized (asciiBytes reason)
        )
        (\reason -> Builder.word8 2 <> sized (asciiBytes reason))
        (\reason -> Builder.word8 3 <> sized (asciiBytes reason))
        ( \report ->
            Builder.word8 4
                <> sized (asciiBytes (conflictSubject report))
                <> originBody (conflictExpected report)
                <> originBody (conflictObserved report)
        )

originBody :: Origin -> Builder.Builder
originBody OriginAbsent = Builder.word8 0
originBody (OriginPresent identity) = Builder.word8 1 <> sized (objectIdentityBytes identity)

getFault :: Decoder OwnershipFault
getFault = do
    kind <- getWord8
    case kind of
        0 -> OwnershipUnsupported <$> getText "an unsupported refusal's reason"
        1 ->
            OwnershipProbeFailed
                <$> getText "a probe failure's operation"
                <*> getText "a probe failure's reason"
        2 -> OwnershipMalformed <$> getText "a malformed refusal's reason"
        3 -> OwnershipOccupied <$> getText "an occupied refusal's reason"
        4 -> do
            subject <- getText "a conflict's subject"
            expected <- getOrigin
            observed <- getOrigin
            pure
                ( OwnershipConflict
                    ConflictReport
                        { conflictSubject = subject
                        , conflictExpected = expected
                        , conflictObserved = observed
                        }
                )
        _ -> refuse "the ownership outcome names an unknown refusal"

getOrigin :: Decoder Origin
getOrigin = do
    tag <- getWord8
    case tag of
        0 -> pure OriginAbsent
        1 -> OriginPresent <$> getIdentity
        _ -> refuse "the ownership outcome names an unknown prior state"

getIdentity :: Decoder ObjectIdentity
getIdentity = do
    bytes <- getSized "an object identity"
    either (const (refuse "the ownership outcome carries no usable identity")) pure (mkObjectIdentity bytes)

-- ---------------------------------------------------------------------------
-- One strict decoder

{- | The widest field this wire admits.

getSized applies one 4 MiB bound to every length-framed field, paths included.
Later field admission can be narrower, as it is for object identities. The
encoder does not enforce this ceiling. The transport's whole-body bound is
separate.
-}
shippedFieldCeiling :: Word32
shippedFieldCeiling = 4 * 1024 * 1024

newtype Decoder value = Decoder
    { runDecoder :: ByteString -> Either Text (value, ByteString)
    }

instance Functor Decoder where
    fmap transform (Decoder decode) = Decoder $ \input -> do
        (value, rest) <- decode input
        Right (transform value, rest)

instance Applicative Decoder where
    pure value = Decoder (\input -> Right (value, input))
    Decoder decodeFunction <*> Decoder decodeValue = Decoder $ \input -> do
        (function, afterFunction) <- decodeFunction input
        (value, afterValue) <- decodeValue afterFunction
        Right (function value, afterValue)

instance Monad Decoder where
    Decoder decodeValue >>= next = Decoder $ \input -> do
        (value, rest) <- decodeValue input
        runDecoder (next value) rest

refuse :: Text -> Decoder value
refuse reason = Decoder (const (Left reason))

{- | Run one decoder over the whole input, refusing anything left over.

A trailing byte is a refusal rather than a remainder, because a value only part
of which this frame understands is the one input that could make it act on
something nobody sent.
-}
runExact :: Text -> ByteString -> Decoder value -> Either OwnershipFault value
runExact subject raw decoder = case runDecoder decoder raw of
    Left reason -> Left (OwnershipMalformed (subject <> ": " <> reason))
    Right (_, trailing)
        | not (ByteString.null trailing) ->
            Left (OwnershipMalformed (subject <> " has trailing bytes"))
    Right (value, _) -> Right value

checkMagic :: ByteString -> Text -> Decoder ()
checkMagic expected subject = do
    observed <- getBytes (ByteString.length expected)
    if observed == expected
        then pure ()
        else refuse (subject <> " has an unknown format")

getWord8 :: Decoder Word8
getWord8 = ByteString.head <$> getBytes 1

getWord32LE :: Decoder Word32
getWord32LE = word32LE <$> getBytes 4

getSized :: Text -> Decoder ByteString
getSized subject = do
    width <- getWord32LE
    if width > shippedFieldCeiling
        then refuse (subject <> " exceeds this wire's field ceiling")
        else getBytes (fromIntegral width)

getText :: Text -> Decoder Text
getText subject = do
    bytes <- getSized subject
    case TextEncoding.decodeUtf8' bytes of
        Left _ -> refuse (subject <> " is not text")
        Right value -> pure value

getAdmittedPath :: (FilePath -> Either OwnershipFault path) -> Text -> Decoder path
getAdmittedPath admit subject = do
    text <- getText subject
    case admit (Text.unpack text) of
        Left fault -> refuse (Text.pack (show fault))
        Right path -> pure path

getBytes :: Int -> Decoder ByteString
getBytes count = Decoder $ \input ->
    if count < 0 || ByteString.length input < count
        then Left "the value is truncated"
        else Right (ByteString.take count input, ByteString.drop count input)

sized :: ByteString -> Builder.Builder
sized bytes = Builder.word32LE (fromIntegral (ByteString.length bytes)) <> Builder.byteString bytes

asciiBytes :: Text -> ByteString
asciiBytes = TextEncoding.encodeUtf8

strict :: Builder.Builder -> ByteString
strict = LazyByteString.toStrict . Builder.toLazyByteString
