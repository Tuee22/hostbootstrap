{-# LANGUAGE CPP #-}
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
seam over the very same row, because every frame this project reaches is Linux.

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
    ShippedOwnership (..),
    ShippedAct (..),
    encodeShippedOwnership,
    decodeShippedOwnership,

    -- * The outcome
    ShippedOutcome (..),
    encodeShippedOutcome,
    decodeShippedOutcome,

    -- * The near side
    shipOwnedTransaction,

    -- * The far side
    interpretShippedOwnership,
    runShippedOwnership,
)
where

import Control.Exception (IOException, displayException, try)
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word32, Word8)
import HostBootstrap.Handoff.Transaction (withFrameChildTransaction)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lift (LiftContext, SelfRef)
import HostBootstrap.Ownership.Clause (enteredEvidence)
import HostBootstrap.Ownership.Object (
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
    mkKernelObjectIdentity,
    mkObjectIdentity,
    mkOwnerClaim,
    mkPayload,
    objectIdentityBytes,
    originRecordBinding,
    originRecordKind,
    originRecordOrigin,
    ownershipFault,
    parseOriginRecord,
    payloadBytes,
    payloadDigest,
    renderOriginRecord,
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
    reenterOwnedObject,
    releaseOwnedObject,
    releaseReportedObject,
    reobserveOwnedIdentity,
    reobserveReportedIdentity,
    rowSyncParent,
    withOwnershipRow,
 )
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    RecordKey,
    compareAndDeleteProtectedRecord,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
    readProtectedRecord,
    recordKeyText,
    withProtectedEntry,
 )
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
#ifndef mingw32_HOST_OS
import System.Posix.Files
    ( createLink
    , createSymbolicLink
    , deviceID
    , fileID
    , getSymbolicLinkStatus
    , isSymbolicLink
    , readSymbolicLink
    , removeLink
    )
#endif

-- ---------------------------------------------------------------------------
-- The transaction

{- | One complete ownership transaction, addressed to the frame that owns the
object.

Everything the far side is entitled to is here, and nothing else. It receives no
pathname policy, no command to run, and no authority: it is told which protected
store holds this object's clauses, which record names it, which object it is,
and which of a closed set of acts to perform.
-}
data ShippedOwnership = ShippedOwnership
    { shippedAuthority :: FilePath
    -- ^ where the far side keeps this object's exclusive entry and durable record
    , shippedRecord :: RecordKey
    -- ^ the durable record that names this object
    , shippedTarget :: FilePath
    -- ^ the object itself, in the far frame's own grammar (§ MM)
    , shippedAct :: ShippedAct
    }
    deriving (Eq, Show)

{- | The closed set of acts a shipped transaction may name.

Four, because they are the four things the seam's producers compose over one
object. There is no act that runs a command, because a described command travels
through the one interpreter (§ KK) and an act that could run a string would make
this a shell again.
-}
data ShippedAct
    = -- | report what is there, and mutate nothing
      ShipObserveObject
    | -- | clauses 1–3 over a directory this transaction creates
      ShipTakeDirectory
    | -- | clauses 1–3 over a file this transaction publishes
      ShipTakeFile Payload
    | -- | clause 4, re-entered from the durable record the far side holds
      ShipGiveBackObject
    | -- | clauses 1–3 over a symbolic link published without replacement
      ShipTakeSymbolicLink FilePath
    | -- | clause 4 over that symbolic link and its exact target
      ShipGiveBackSymbolicLink FilePath
    deriving (Eq, Show)

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

{- | Run one ownership transaction at the frame @context@ names.

The invocation comes from the lift's one fold and the process group is ended on
every exit path, because both belong to the crossing this call is wrapped in.
What is added here is only the transaction's own encoding and the outcome's own
decoding, so a failure of the crossing and a refusal by the frame stay distinct:
the first is a probe that could not be made, the second is an answer.
-}
shipOwnedTransaction ::
    HostConfig ->
    SelfRef ->
    LiftContext ->
    ShippedOwnership ->
    IO (Either OwnershipFault ShippedOutcome)
shipOwnedTransaction config self context transaction = do
    crossed <-
        withFrameChildTransaction
            config
            self
            context
            (encodeShippedOwnership transaction)
    pure $ case crossed of
        Left failure ->
            Left
                ( OwnershipProbeFailed
                    "run an ownership transaction at the frame that owns the object"
                    failure
                )
        Right raw -> case decodeShippedOutcome raw of
            Left fault -> Left fault
            Right (ShippedRefused fault) -> Left fault
            Right outcome -> Right outcome

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
runShippedOwnership row transaction = do
    opened <- openProtectedStore (shippedAuthority transaction)
    case opened of
        Left failure -> pure (refusedByStore "open this frame's ownership authority" failure)
        Right store -> do
            entered <-
                withProtectedEntry store $ \session ->
                    Right <$> inEntry row transaction session
            pure $ case entered of
                Left failure -> refusedByStore "enter this frame's ownership authority" failure
                Right outcome -> outcome

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
    ShipTakeSymbolicLink linkTarget -> takeSymbolicLink linkTarget
    ShipGiveBackSymbolicLink linkTarget -> giveBackSymbolicLink linkTarget
  where
    key = shippedRecord transaction
    target = shippedTarget transaction
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
        stored <- readBoundRecord session key
        case stored of
            Left fault -> pure (ShippedRefused fault)
            Right (Just record) -> pure (retried record)
            Right Nothing -> do
                outcome <- enterOwnedObject row session target $ \entered ->
                    enteredEvidence
                        ( \_target origin -> case origin of
                            OriginPresent _ -> pure (Left (occupied target))
                            OriginAbsent -> createUnder entered kind payload
                        )
                        entered
                pure (settle outcome)

    retried record = case originRecordBinding record of
        Just identity -> ShippedObjectTaken identity
        Nothing ->
            ShippedRefused
                ( OwnershipMalformed
                    "this frame holds an unbound record for the object, so a previous transaction did not get past clause 2"
                )

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

    giveBack = do
        stored <- readBoundRecord session key
        case stored of
            Left fault -> pure (ShippedRefused fault)
            Right Nothing -> pure ShippedObjectGivenBack
            Right (Just record) -> do
                outcome <- reenterOwnedObject row session target record $ \bound -> do
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
                        (ReportedObject (symbolicLinkClaim linkTarget))
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
                    Right present -> pure (ShippedRefused (symbolicLinkIdentityConflict target identity present))
            Right Nothing -> do
                outcome <-
                    enterReportedObject session target OriginAbsent $ \entered -> do
                        recorded <-
                            recordReportedOrigin
                                entered
                                (ReportedObject (symbolicLinkClaim linkTarget))
                                (publishExactRecord session key record)
                        case recorded of
                            Left fault -> pure (Left fault)
                            Right token -> publishSymbolicLink linkTarget token ShippedSymbolicLinkRetained
                pure (settle outcome)

    publishSymbolicLink linkTarget recorded answer = do
        published <- createOrRecoverSymbolicLink row transaction linkTarget
        case published of
            Left fault -> pure (Left fault)
            Right identity -> do
                bound <- bindReportedIdentity recorded identity (publishBinding session key)
                case bound of
                    Left fault -> pure (Left fault)
                    Right _ -> do
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
                    Right Nothing -> pure (ShippedRefused (OwnershipMalformed "the symbolic-link record has no identity binding"))
                    Right (Just identity) -> releaseSymbolicLink linkTarget record identity

    releaseSymbolicLink linkTarget record identity = do
        observed <- observeSymbolicLink target linkTarget
        case observed of
            Left fault -> pure (ShippedRefused fault)
            Right SymbolicLinkAbsent -> do
                forgotten <- forget session key record
                pure (either ShippedRefused (const ShippedObjectGivenBack) forgotten)
            Right (SymbolicLinkExact current)
                | current == identity -> do
                    outcome <-
                        enterReportedObject session target OriginAbsent $ \entered -> do
                            recorded <-
                                recordReportedOrigin
                                    entered
                                    (ReportedObject (symbolicLinkClaim linkTarget))
                                    (publishExactRecord session key record)
                            case recorded of
                                Left fault -> pure (Left fault)
                                Right token -> do
                                    rebound <- bindReportedIdentity token identity (publishExactRecord session key record)
                                    case rebound of
                                        Left fault -> pure (Left fault)
                                        Right bound -> case reobserveReportedIdentity bound (OriginPresent current) of
                                            Left fault -> pure (Left fault)
                                            Right releasable -> do
                                                removed <- removeExactSymbolicLink row target
                                                case removed of
                                                    Left fault -> pure (Left fault)
                                                    Right () ->
                                                        releaseReportedObject releasable OriginAbsent (forget session key)
                    pure (either ShippedRefused (const ShippedObjectGivenBack) outcome)
            Right present -> pure (ShippedRefused (symbolicLinkIdentityConflict target identity present))

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
    shippedTarget transaction
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
symbolicLinkIdentityConflict path expected observation =
    OwnershipConflict
        ConflictReport
            { conflictSubject = Text.pack path
            , conflictExpected = OriginPresent expected
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
    statusResult <- try (getSymbolicLinkStatus path)
    case statusResult of
        Left failure
            | isDoesNotExistError failure -> pure (Right SymbolicLinkAbsent)
            | otherwise -> pure (Left (symbolicLinkProbe "observe" path failure))
        Right status -> do
            identity <- pure (mkKernelObjectIdentity (fromIntegral (deviceID status)) (fromIntegral (fileID status)))
            case identity of
                Left fault -> pure (Left fault)
                Right stable
                    | not (isSymbolicLink status) -> pure (Right (SymbolicLinkOther (Just stable)))
                    | otherwise -> do
                        targetResult <- try (readSymbolicLink path)
                        pure $ case targetResult of
                            Left failure -> Left (symbolicLinkProbe "read" path failure)
                            Right actual
                                | actual == linkTarget -> Right (SymbolicLinkExact stable)
                                | otherwise -> Right (SymbolicLinkOther (Just stable))
#endif

createOrRecoverSymbolicLink :: OwnershipRow -> ShippedOwnership -> FilePath -> IO (Either OwnershipFault ObjectIdentity)
#ifdef mingw32_HOST_OS
createOrRecoverSymbolicLink _row _transaction _linkTarget =
    pure (Left (OwnershipUnsupported "symbolic-link ownership is available only in a POSIX frame"))
#else
createOrRecoverSymbolicLink row transaction linkTarget = do
    let stage = stagingOf transaction
        target = shippedTarget transaction
    stageObserved <- observeSymbolicLink stage linkTarget
    case stageObserved of
        Left fault -> pure (Left fault)
        Right SymbolicLinkAbsent -> do
            created <- try (createSymbolicLink linkTarget stage)
            case created of
                Left failure -> pure (Left (symbolicLinkProbe "create staging" stage failure))
                Right () -> do
                    synced <- syncSymbolicLinkParent row stage
                    either (pure . Left) (const (publishStage stage target)) synced
        Right (SymbolicLinkExact _) -> publishStage stage target
        Right other -> pure (Left (symbolicLinkOccupied stage other))
  where
    publishStage stage target = do
        staged <- observeSymbolicLink stage linkTarget
        case staged of
            Right (SymbolicLinkExact stagedIdentity) -> do
                linked <- try (createLink stage target)
                case linked of
                    Left failure
                        | isAlreadyExistsError failure -> do
                            synced <- syncSymbolicLinkParent row target
                            either (pure . Left) (const (confirmPublished stage stagedIdentity target)) synced
                        | otherwise -> pure (Left (symbolicLinkProbe "publish" target failure))
                    Right () -> do
                        synced <- syncSymbolicLinkParent row target
                        either (pure . Left) (const (confirmPublished stage stagedIdentity target)) synced
            Right other -> pure (Left (symbolicLinkOccupied stage other))
            Left fault -> pure (Left fault)

    confirmPublished _stage stagedIdentity target = do
        observed <- observeSymbolicLink target linkTarget
        pure $ case observed of
            Right (SymbolicLinkExact identity)
                | identity == stagedIdentity -> Right identity
            Right other -> Left (symbolicLinkIdentityConflict target stagedIdentity other)
            Left fault -> Left fault
#endif

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
        Right SymbolicLinkAbsent -> pure (Right ())
        Right (SymbolicLinkExact current)
            | current == identity -> removeExactSymbolicLink row stage
        Right other -> pure (Left (symbolicLinkIdentityConflict stage identity other))
#endif

removeExactSymbolicLink :: OwnershipRow -> FilePath -> IO (Either OwnershipFault ())
#ifdef mingw32_HOST_OS
removeExactSymbolicLink _row _path =
    pure (Left (OwnershipUnsupported "symbolic-link ownership is available only in a POSIX frame"))
#else
removeExactSymbolicLink row path = do
    removed <- try (removeLink path)
    case removed of
        Left failure -> pure (Left (symbolicLinkProbe "remove" path failure))
        Right () -> syncSymbolicLinkParent row path
#endif

syncSymbolicLinkParent :: OwnershipRow -> FilePath -> IO (Either OwnershipFault ())
syncSymbolicLinkParent row path =
    withOwnershipRow row (\primitives -> rowSyncParent primitives path)

symbolicLinkProbe :: Text -> FilePath -> IOException -> OwnershipFault
symbolicLinkProbe operation path failure =
    OwnershipProbeFailed
        (operation <> " symbolic link " <> Text.pack path)
        (Text.pack (displayException failure))

-- ---------------------------------------------------------------------------
-- Clause 2, in the far frame's own store

readBoundRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either OwnershipFault (Maybe OriginRecord))
readBoundRecord session key = do
    stored <- readProtectedRecord session key
    pure $ case stored of
        Left failure -> Left (storeFault "read this object's ownership record" failure)
        Right Nothing -> Right Nothing
        Right (Just stamped) ->
            fmap Just (parseOriginRecord (protectedRecordBytes stamped))

publishOrigin ::
    ProtectedSession session ->
    RecordKey ->
    OriginRecord ->
    IO (Either OwnershipFault ())
publishOrigin session key record = do
    written <-
        compareAndSwapProtectedRecord session key ExpectAbsent (renderOriginRecord record)
    pure
        ( either
            (Left . storeFault "publish this object's origin record")
            (const (Right ()))
            written
        )

{- | Publish the binding against the exact version the origin publication left,
read back inside the same exclusive entry.
-}
publishBinding ::
    ProtectedSession session ->
    RecordKey ->
    OriginRecord ->
    IO (Either OwnershipFault ())
publishBinding session key record = do
    current <- readProtectedRecord session key
    case current of
        Left failure ->
            pure (Left (storeFault "read this object's origin record" failure))
        Right Nothing ->
            pure
                ( Left
                    ( OwnershipProbeFailed
                        "bind this object's identity"
                        "the origin record vanished inside the exclusive entry"
                    )
                )
        Right (Just stored) -> do
            written <-
                compareAndSwapProtectedRecord
                    session
                    key
                    (ExpectVersion (protectedRecordVersion stored))
                    (renderOriginRecord record)
            pure
                ( either
                    (Left . storeFault "bind this object's identity")
                    (const (Right ()))
                    written
                )

forget ::
    ProtectedSession session ->
    RecordKey ->
    OriginRecord ->
    IO (Either OwnershipFault ())
forget session key _record = do
    observed <- readProtectedRecord session key
    case observed of
        Left failure -> pure (Left (storeFault "read this object's ownership record" failure))
        Right Nothing -> pure (Right ())
        Right (Just stored) -> do
            deleted <-
                compareAndDeleteProtectedRecord
                    session
                    key
                    (ExpectVersion (protectedRecordVersion stored))
            pure
                ( either
                    (Left . storeFault "forget this object's ownership record")
                    Right
                    deleted
                )

storeFault :: Text -> ProtectedError -> OwnershipFault
storeFault operation failure = OwnershipProbeFailed operation (protectedErrorMessage failure)

refusedByStore :: Text -> ProtectedError -> ShippedOutcome
refusedByStore operation = ShippedRefused . storeFault operation

-- ---------------------------------------------------------------------------
-- The wire

{- | The transaction, exactly.

Length-framed rather than delimited, because a target path and a payload are
arbitrary bytes and a delimiter would make one of them able to describe the
next field.
-}
encodeShippedOwnership :: ShippedOwnership -> ByteString
encodeShippedOwnership transaction =
    strict
        ( Builder.byteString transactionMagic
            <> Builder.word8 (actTag (shippedAct transaction))
            <> sized (asciiBytes (Text.pack (shippedAuthority transaction)))
            <> sized (asciiBytes (recordKeyText (shippedRecord transaction)))
            <> sized (asciiBytes (Text.pack (shippedTarget transaction)))
            <> payloadField (shippedAct transaction)
        )
  where
    payloadField (ShipTakeFile payload) = sized (payloadBytes payload)
    payloadField (ShipTakeSymbolicLink target) = sized (asciiBytes (Text.pack target))
    payloadField (ShipGiveBackSymbolicLink target) = sized (asciiBytes (Text.pack target))
    payloadField _ = mempty

decodeShippedOwnership :: ByteString -> Either OwnershipFault ShippedOwnership
decodeShippedOwnership raw = runExact "ownership transaction" raw $ do
    checkMagic transactionMagic "ownership transaction"
    tag <- getWord8
    authority <- getText "the ownership transaction's authority"
    rawKey <- getText "the ownership transaction's record key"
    target <- getText "the ownership transaction's target"
    act <- case tag of
        0 -> pure ShipObserveObject
        1 -> pure ShipTakeDirectory
        2 -> ShipTakeFile . mkPayload <$> getSized "the ownership transaction's payload"
        3 -> pure ShipGiveBackObject
        4 -> ShipTakeSymbolicLink . Text.unpack <$> getText "the symbolic link's target"
        5 -> ShipGiveBackSymbolicLink . Text.unpack <$> getText "the symbolic link's target"
        _ -> refuse "the ownership transaction names an unknown act"
    key <- case mkRecordKey rawKey of
        Left failure ->
            refuse
                ( "the ownership transaction's record key is not a record key: "
                    <> protectedErrorMessage failure
                )
        Right key -> pure key
    pure
        ShippedOwnership
            { shippedAuthority = Text.unpack authority
            , shippedRecord = key
            , shippedTarget = Text.unpack target
            , shippedAct = act
            }

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

A ceiling rather than a length, because a target path and a payload differ by
orders of magnitude and a single bound would either refuse a legitimate payload
or admit an absurd pathname. The transport's own body bound is authoritative
above this.
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
getWord32LE = do
    bytes <- getBytes 4
    pure
        ( fromIntegral (ByteString.index bytes 0)
            .|. shiftL (fromIntegral (ByteString.index bytes 1)) 8
            .|. shiftL (fromIntegral (ByteString.index bytes 2)) 16
            .|. shiftL (fromIntegral (ByteString.index bytes 3)) 24
        )

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
