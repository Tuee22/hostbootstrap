{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Locked-Origin Identity Ownership for a harness run's generated sibling
@\<project\>.dhall@.

A run generates its own project config, and it must be able to remove /exactly/
the file it installed — never a production config an operator put there, and
never a replacement that appeared under the same name while the run was live.

The four clauses of @development_plan_standards.md § EE@ are one transaction and
are written once, in "HostBootstrap.Ownership.Primitive". This module is a
/consumer/ of that seam rather than a second implementation of it: the identity
read, the durable record's encoding, the atomic no-replace publication, and the
identity-conditional act each live there, and what is here is only the policy
that is genuinely the generated config's own.

That policy is two rules:

* a **found object is refused** before any record is written, and is never
  adopted and never replaced. A generated config cannot coexist with a config
  that is already there, so the authoritative "a production config already
  exists" refusal is this one — and because it runs inside the ownership
  bracket, it runs /after/ the abandoned-run sweep rather than ahead of it;
* release is conditional on the re-observed identity **and** the payload. Clause
  4 in the seam decides authority — this is the object this run created — and
  the payload comparison that follows it decides that the bytes are still the
  ones this run installed. An edited file is therefore left intact even though
  it is the same object.

Clause 1 is the caller's 'ProtectedSession': every entry point demands one, so
the whole transaction cannot straddle another run's, and the kernel releases the
entry if this process dies inside the bracket. Clause 2's durable record is the
canonical 'OriginRecord' written through the protected store's own
compare-and-swap, and its file case carries the digest of the payload this run
intends to install. Recording that digest before the write is what makes the
crash window between the record and the identity binding resolvable: a run that
died in that window left a file whose bytes either are this payload — in which
case it is that run's and may be removed — or are not, in which case they belong
to whoever wrote them.

"HostBootstrap.Harness.DataRoot" is the same four-clause protocol over the run's
data-root /directory/, through the same seam, so the two cannot drift.
-}
module HostBootstrap.Harness.GeneratedConfig (
    -- * Ownership
    GeneratedConfigOwnership,
    generatedConfigOwnershipPath,
    generatedConfigOwnershipDigest,
    generatedConfigOwnershipManaged,

    -- * Driver
    GeneratedConfigError (..),
    generatedConfigErrorMessage,
    acquireGeneratedConfig,
    GeneratedConfigRelease (..),
    releaseGeneratedConfig,
    RecoveredGeneratedConfig (..),
    recoverGeneratedConfig,
) where

import Control.Exception.Safe (try)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Ownership.Clause (enteredEvidence)
import HostBootstrap.Ownership.Object (
    ConflictReport (conflictExpected, conflictObserved, conflictSubject),
    ObjectIdentity,
    ObjectKind (OwnedDirectory, OwnedFile),
    Origin (OriginAbsent, OriginPresent),
    OriginRecord,
    OwnershipFault (OwnershipMalformed, OwnershipProbeFailed),
    PayloadDigest,
    mkPayload,
    objectIdentityText,
    originRecordBinding,
    originRecordKind,
    ownershipFault,
    parseOriginRecord,
    payloadDigest,
    payloadDigestText,
    renderOriginRecord,
 )
import HostBootstrap.Ownership.Primitive (
    OwnershipPrimitive (rowCloseHandle, rowOpenExclusive, rowReadObject, rowRemoveObject),
    OwnershipRow,
    bindOwnedIdentity,
    enterOwnedObject,
    publishOwnedFile,
    recordOwnedOrigin,
    reenterOwnedObject,
    releaseOwnedObject,
    reobserveOwnedIdentity,
    withOwnershipRow,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    RecordKey,
    compareAndDeleteProtectedRecord,
    compareAndSwapProtectedRecord,
    protectedErrorMessage,
    readProtectedRecord,
    recordKeyText,
 )
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))

-- Ownership ------------------------------------------------------------------------

{- | The receipt for one installed generated config.  Its constructor is
private, so it exists only where 'acquireGeneratedConfig' created the file and
bound its identity.  'releaseGeneratedConfig' revalidates the path and record
key it names, so one run's receipt cannot release another's.
-}
data GeneratedConfigOwnership = GeneratedConfigOwnership
    { ownershipPath :: FilePath
    , ownershipKey :: Text
    , ownershipDigest :: PayloadDigest
    , ownershipManaged :: ObjectIdentity
    }
    deriving (Eq, Show)

generatedConfigOwnershipPath :: GeneratedConfigOwnership -> FilePath
generatedConfigOwnershipPath = ownershipPath

generatedConfigOwnershipDigest :: GeneratedConfigOwnership -> PayloadDigest
generatedConfigOwnershipDigest = ownershipDigest

generatedConfigOwnershipManaged :: GeneratedConfigOwnership -> ObjectIdentity
generatedConfigOwnershipManaged = ownershipManaged

-- Failures -------------------------------------------------------------------------

data GeneratedConfigError
    = -- | The host cannot hold a clause; no receipt is minted.
      GeneratedConfigUnsupported Text
    | -- | Something is already at the path; it is never adopted or replaced.
      GeneratedConfigOccupied FilePath
    | -- | The object at the path is not the one ownership names, or its bytes
      -- are not the ones this run installed.
      GeneratedConfigConflict Text Text Text
    | -- | The durable origin record could not be interpreted.
      GeneratedConfigMalformedRecord Text
    | -- | The protected store refused or failed.
      GeneratedConfigStoreFailure ProtectedError
    | -- | A filesystem operation failed.
      GeneratedConfigFailure Text Text
    deriving (Eq, Show)

generatedConfigErrorMessage :: GeneratedConfigError -> Text
generatedConfigErrorMessage failure = case failure of
    GeneratedConfigUnsupported reason ->
        "the generated config cannot be owned on this host: " <> reason
    GeneratedConfigOccupied path ->
        "a config already exists at "
            <> Text.pack path
            <> "; refusing to overwrite it"
    GeneratedConfigConflict path expected observed ->
        "the generated config "
            <> path
            <> " is not the file this run owns (expected "
            <> expected
            <> ", observed "
            <> observed
            <> "); it was left intact"
    GeneratedConfigMalformedRecord reason ->
        "the generated-config ownership record is malformed: " <> reason
    GeneratedConfigStoreFailure inner -> protectedErrorMessage inner
    GeneratedConfigFailure operation reason ->
        "could not " <> operation <> ": " <> reason

{- | Carry the seam's closed fault sum across into this protocol's vocabulary.

Through the total eliminator, so a case added to the seam's sum is a compile
error here rather than a branch that quietly falls through.
-}
ownershipError :: OwnershipFault -> GeneratedConfigError
ownershipError =
    ownershipFault
        GeneratedConfigUnsupported
        GeneratedConfigFailure
        GeneratedConfigMalformedRecord
        (GeneratedConfigFailure "own the generated config")
        ( \report ->
            GeneratedConfigConflict
                (conflictSubject report)
                (renderSide (conflictExpected report))
                (renderSide (conflictObserved report))
        )

renderSide :: Origin -> Text
renderSide OriginAbsent = "absent"
renderSide (OriginPresent identity) = "identity " <> objectIdentityText identity

-- Driver ---------------------------------------------------------------------------

{- | What the acquisition transaction concluded inside the exclusive entry.

The occupied refusal names a path this module already holds, so it is carried
out as a decision rather than pushed through the seam's fault sum, whose
occupied case is about a target a /kernel/ reported occupied.
-}
data AcquisitionOutcome
    = AcquiredOwnership GeneratedConfigOwnership
    | AcquisitionRefusedOccupied

{- | Install the run's generated config inside the caller's exclusive entry.

The order is the seam's, and it is the order § EE states: enter and observe,
publish the origin record naming the recorded absence and the intended payload
digest, only then publish the file through the row's atomic no-replace
primitive, then bind the created file's own kernel identity. An existing record
under this key means a previous incarnation of this exact run did not settle;
that is a conflict for 'recoverGeneratedConfig' to resolve rather than something
to overwrite.
-}
acquireGeneratedConfig ::
    OwnershipRow ->
    ProtectedSession session ->
    RecordKey ->
    FilePath ->
    -- | the exact bytes to install
    ByteString ->
    IO (Either GeneratedConfigError GeneratedConfigOwnership)
acquireGeneratedConfig row session key path bytes = do
    existing <- readRecord session key
    case existing of
        Left failure -> pure (Left failure)
        Right (Just _) ->
            pure
                ( Left
                    ( GeneratedConfigConflict
                        (Text.pack path)
                        "no prior ownership record"
                        ("an unsettled record under " <> recordKeyText key)
                    )
                )
        Right Nothing -> do
            prepared <- ensureParent path
            case prepared of
                Left failure -> pure (Left failure)
                Right () -> do
                    outcome <-
                        enterOwnedObject row session path $ \entered ->
                            enteredEvidence
                                ( \_target origin -> case origin of
                                    -- Never adopted, never replaced, and nothing
                                    -- is recorded: the refusal precedes both the
                                    -- durable record and the first mutation.
                                    OriginPresent _ -> pure (Right AcquisitionRefusedOccupied)
                                    OriginAbsent -> createUnderRecordedAbsence entered
                                )
                                entered
                    pure $ case outcome of
                        Left fault -> Left (ownershipError fault)
                        Right AcquisitionRefusedOccupied -> Left (GeneratedConfigOccupied path)
                        Right (AcquiredOwnership owned) -> Right owned
  where
    payload = mkPayload bytes
    digest = payloadDigest payload

    createUnderRecordedAbsence entered = do
        recorded <- recordOwnedOrigin row entered (OwnedFile digest) publishOrigin
        case recorded of
            Left fault -> pure (Left fault)
            Right token -> do
                published <- publishOwnedFile row token payload (stagingPath key path)
                case published of
                    Left fault -> do
                        discardStaging row (stagingPath key path)
                        pure (Left fault)
                    Right identity -> do
                        bound <- bindOwnedIdentity row token identity publishBinding
                        pure (fmap (const (AcquiredOwnership (receipt identity))) bound)

    publishOrigin record = do
        written <-
            compareAndSwapProtectedRecord
                session
                key
                ExpectAbsent
                (renderOriginRecord record)
        pure
            ( either
                (Left . storeFault "publish the generated-config origin record")
                (const (Right ()))
                written
            )

    -- The binding is published against the exact version the origin publication
    -- left, read back inside the same exclusive entry. Reading it rather than
    -- carrying it out of the seam's continuation is what keeps the store the one
    -- place a version lives.
    publishBinding record = do
        current <- readProtectedRecord session key
        case current of
            Left failure ->
                pure (Left (storeFault "read the generated-config origin record" failure))
            Right Nothing ->
                pure
                    ( Left
                        ( OwnershipProbeFailed
                            "bind the generated-config identity"
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
                        (Left . storeFault "bind the generated-config identity")
                        (const (Right ()))
                        written
                    )

    receipt = GeneratedConfigOwnership path (recordKeyText key) digest

-- | What release did.  Only an exact identity /and/ payload match removes.
data GeneratedConfigRelease = GeneratedConfigRemoved
    deriving (Eq, Show)

{- | What the release transaction concluded once clause 4 had spoken.

A payload mismatch is this owner's own refusal rather than the seam's: clause 4
has already said the object is the one this run created, so what differs is the
bytes, which the seam's identity conflict has no way to report.
-}
data ReleaseOutcome
    = ReleasedRemoved
    | ReleaseRefusedPayload PayloadDigest PayloadDigest

{- | Release ownership inside the caller's exclusive entry (clause 4).

The release re-enters the object through the seam, using the bound record the
store already holds; the seam re-observes the identity, and only then are the
bytes re-read and compared against the digest that record names. The file is
unlinked only when both match. A replacement, an edit, or a vanished file is a
structured conflict: nothing is removed and the record is retained, so the next
run's sweep sees exactly the same evidence.
-}
releaseGeneratedConfig ::
    OwnershipRow ->
    ProtectedSession session ->
    RecordKey ->
    GeneratedConfigOwnership ->
    IO (Either GeneratedConfigError GeneratedConfigRelease)
releaseGeneratedConfig row session key owned
    | recordKeyText key /= ownershipKey owned =
        pure
            ( Left
                ( GeneratedConfigConflict
                    (Text.pack path)
                    ("ownership record " <> ownershipKey owned)
                    ("release attempted under " <> recordKeyText key)
                )
            )
    | otherwise = do
        stored <- readBoundRecord session key
        case stored of
            Left failure -> pure (Left failure)
            Right Nothing ->
                pure
                    ( Left
                        ( GeneratedConfigConflict
                            (Text.pack path)
                            ("ownership record " <> ownershipKey owned)
                            "no ownership record"
                        )
                    )
            Right (Just record) -> do
                outcome <-
                    reenterOwnedObject row session path record $ \bound -> do
                        releasable <- reobserveOwnedIdentity row bound
                        case releasable of
                            Left fault -> pure (Left fault)
                            Right token -> do
                                -- Clause 4 has confirmed this is the file this run
                                -- created, so what remains is whether its bytes are
                                -- still the ones this run installed.
                                matched <- payloadStillMatches row path record
                                case matched of
                                    Left fault -> pure (Left fault)
                                    Right (Just (expected, observed)) ->
                                        pure (Right (ReleaseRefusedPayload expected observed))
                                    Right Nothing ->
                                        fmap
                                            (fmap (const ReleasedRemoved))
                                            (releaseOwnedObject row token forget)
                pure $ case outcome of
                    Left fault -> Left (ownershipError fault)
                    Right (ReleaseRefusedPayload expected observed) ->
                        Left (payloadConflict path expected observed)
                    Right ReleasedRemoved -> Right GeneratedConfigRemoved
  where
    path = ownershipPath owned
    forget _record = do
        deleted <- deleteRecord session key
        pure (either (Left . forgetFailure) Right deleted)

{- | What recovery restored for an abandoned run's generated config.  Recovery
never adopts: it removes only the exact file that run installed.
-}
data RecoveredGeneratedConfig
    = -- | The recorded payload was found at the recorded identity and removed.
      GeneratedConfigAbsenceRestored
    | -- | Nothing was at the path; the record is settled.
      GeneratedConfigAlreadyAbsent
    deriving (Eq, Show)

{- | What recovery concluded inside its own exclusive entry, before the record
is settled.
-}
data RecoveryOutcome
    = RecoveredAbsence
    | RecoveredNothingThere
    | RecoveryRefusedPayload PayloadDigest PayloadDigest

{- | Resolve an abandoned run's generated-config ownership record.

The record is the authority, which is the point of writing it before the first
mutation.  It says the path was __absent__ and names the digest of the payload
the run intended to install, so:

* no record — the run either never started the transaction or already settled
  it;
* a record with an identity binding — the release path above is exactly what
  recovery runs: re-enter, re-observe, compare the bytes, and remove only on an
  exact match, so a replacement is refused and left intact;
* a record with __no__ binding — the run died inside the crash window between
  clause 2 and clause 3. There is no identity to be conditional on, which is
  what the window means, but the recorded payload digest still decides it:
  nothing at the path settles the record, exactly those bytes are the dead run's
  own file and absence is restored, and anything else is refused and left
  intact.

This is what makes an interrupted run's config self-healing instead of an
operator's hand cleanup, and it is only reachable because the existence refusal
runs after the sweep rather than before it.
-}
recoverGeneratedConfig ::
    OwnershipRow ->
    ProtectedSession session ->
    RecordKey ->
    FilePath ->
    IO (Either GeneratedConfigError RecoveredGeneratedConfig)
recoverGeneratedConfig row session key path = do
    stored <- readBoundRecord session key
    case stored of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Right GeneratedConfigAlreadyAbsent)
        Right (Just record) -> case originRecordBinding record of
            Just _ -> reclaimBoundFile record
            Nothing -> restoreRecordedAbsence record
  where
    reclaimBoundFile record = do
        outcome <-
            reenterOwnedObject row session path record $ \bound -> do
                releasable <- reobserveOwnedIdentity row bound
                case releasable of
                    Left fault -> pure (Left fault)
                    Right token -> do
                        matched <- payloadStillMatches row path record
                        case matched of
                            Left fault -> pure (Left fault)
                            Right (Just (expected, observed)) ->
                                pure (Right (RecoveryRefusedPayload expected observed))
                            Right Nothing ->
                                fmap
                                    (fmap (const RecoveredAbsence))
                                    (releaseOwnedObject row token forget)
        settleOutcome outcome

    -- The clause-2/clause-3 crash window. No identity was ever bound, so there
    -- is nothing for clause 4 to be conditional on and the seam has no term for
    -- the removal; what the record proves is that a file holding exactly these
    -- bytes was generated inside that transaction, so restoring absence is this
    -- owner's own policy rather than a release.
    restoreRecordedAbsence record = do
        outcome <-
            enterOwnedObject row session path $ \entered ->
                enteredEvidence
                    ( \target origin -> case origin of
                        OriginAbsent -> pure (Right RecoveredNothingThere)
                        OriginPresent _ -> do
                            matched <- payloadStillMatches row target record
                            case matched of
                                Left fault -> pure (Left fault)
                                Right (Just (expected, observed)) ->
                                    pure (Right (RecoveryRefusedPayload expected observed))
                                Right Nothing ->
                                    fmap
                                        (fmap (const RecoveredAbsence))
                                        (removeThroughRow row target)
                    )
                    entered
        settleOutcome outcome

    settleOutcome outcome = case outcome of
        Left fault -> pure (Left (ownershipError fault))
        Right (RecoveryRefusedPayload expected observed) ->
            pure (Left (payloadConflict path expected observed))
        Right RecoveredNothingThere -> settle GeneratedConfigAlreadyAbsent
        Right RecoveredAbsence -> pure (Right GeneratedConfigAbsenceRestored)

    forget _record = do
        deleted <- deleteRecord session key
        pure (either (Left . forgetFailure) Right deleted)

    settle outcome = do
        deleted <- deleteRecord session key
        pure (fmap (const outcome) deleted)

-- The payload half of clause 4 -------------------------------------------------------

{- | Re-read the object's bytes through the row and compare them with the digest
the durable record names.

'Nothing' means the bytes are still this run's; @'Just' (expected, observed)@
names both sides of a mismatch, so the refusal reports what it was looking for
as well as what it found. The read goes through the row's exclusive open, so the
file this owner compares is opened without following a link and by the same
primitives that created it.

A record this owner wrote always describes a file, so a directory record under
this owner's key is a record something else wrote and is refused rather than
compared.
-}
payloadStillMatches ::
    OwnershipRow ->
    FilePath ->
    OriginRecord ->
    IO (Either OwnershipFault (Maybe (PayloadDigest, PayloadDigest)))
payloadStillMatches row target record = case originRecordKind record of
    OwnedDirectory ->
        pure
            ( Left
                ( OwnershipMalformed
                    "the generated-config ownership record describes a directory"
                )
            )
    OwnedFile expected -> do
        contents <- readThroughRow row target
        pure $ case contents of
            Left fault -> Left fault
            Right bytes ->
                let observed = payloadDigest (mkPayload bytes)
                in Right
                    ( if observed == expected
                        then Nothing
                        else Just (expected, observed)
                    )

payloadConflict :: FilePath -> PayloadDigest -> PayloadDigest -> GeneratedConfigError
payloadConflict path expected observed =
    GeneratedConfigConflict
        (Text.pack path)
        ("payload " <> payloadDigestText expected)
        ("payload " <> payloadDigestText observed)

-- Row plumbing ------------------------------------------------------------------------

{- | Read one whole object through the row's exclusive open, closing the handle
however the read went.
-}
readThroughRow :: OwnershipRow -> FilePath -> IO (Either OwnershipFault ByteString)
readThroughRow row target =
    withOwnershipRow row $ \primitives -> do
        opened <- rowOpenExclusive primitives target
        case opened of
            Left fault -> pure (Left fault)
            Right handle -> do
                contents <- rowReadObject primitives handle
                closed <- rowCloseHandle primitives handle
                pure $ case (contents, closed) of
                    (Left fault, _) -> Left fault
                    (_, Left fault) -> Left fault
                    (Right bytes, Right ()) -> Right bytes

-- | Remove exactly the named object through the row.
removeThroughRow :: OwnershipRow -> FilePath -> IO (Either OwnershipFault ())
removeThroughRow row target = withOwnershipRow row (\primitives -> rowRemoveObject primitives target)

{- | Give back the staging object a failed publication left behind.

The staging name is this owner's own construct rather than an owned object, so
withdrawing it is policy and its outcome never displaces the fault that caused
the withdrawal.
-}
discardStaging :: OwnershipRow -> FilePath -> IO ()
discardStaging row staging = do
    _ <- removeThroughRow row staging
    pure ()

{- | Where the payload is written before it is published.

Beside the target, because the publication is a hard link and a link cannot
cross a filesystem, and named after the record key, which carries this run's own
generative identifier — so two runs never stage through one name and a name left
by a dead run is never reused.
-}
stagingPath :: RecordKey -> FilePath -> FilePath
stagingPath key path =
    takeDirectory path </> ("." <> Text.unpack (recordKeyText key) <> ".hostbootstrap-staging")

-- Shared plumbing --------------------------------------------------------------------

readRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either GeneratedConfigError (Maybe ProtectedRecord))
readRecord session key = do
    observed <- readProtectedRecord session key
    pure (either (Left . GeneratedConfigStoreFailure) Right observed)

-- | The durable record, decoded through the one canonical codec, when one is there.
readBoundRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either GeneratedConfigError (Maybe OriginRecord))
readBoundRecord session key = do
    stored <- readRecord session key
    pure $ case stored of
        Left failure -> Left failure
        Right Nothing -> Right Nothing
        Right (Just stamped) ->
            either
                (Left . ownershipError)
                (Right . Just)
                (parseOriginRecord (protectedRecordBytes stamped))

{- | Delete the ownership record against the exact version just observed, so a
concurrent writer cannot have its record removed by this settlement.
-}
deleteRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either GeneratedConfigError ())
deleteRecord session key = do
    observed <- readRecord session key
    case observed of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Right ())
        Right (Just record) -> do
            deleted <-
                compareAndDeleteProtectedRecord
                    session
                    key
                    (ExpectVersion (protectedRecordVersion record))
            pure (either (Left . GeneratedConfigStoreFailure) Right deleted)

{- | Carry a store failure into the seam's fault vocabulary.

The seam's publication is a continuation, so a caller's own failure has to be
reported in the seam's terms while it is inside one. The store's exact message
survives; what does not is the structured 'ProtectedError', which no caller of
this module matches on for a publication.
-}
storeFault :: Text -> ProtectedError -> OwnershipFault
storeFault operation failure = OwnershipProbeFailed operation (protectedErrorMessage failure)

forgetFailure :: GeneratedConfigError -> OwnershipFault
forgetFailure failure =
    OwnershipProbeFailed
        "forget the generated-config ownership record"
        (generatedConfigErrorMessage failure)

{- | Create the generated config's parent, which is ordinary project scaffolding
and not the owned object itself.
-}
ensureParent :: FilePath -> IO (Either GeneratedConfigError ())
ensureParent path =
    ioAttempt
        "create the generated config's parent directory"
        (createDirectoryIfMissing True (takeDirectory path))

ioAttempt :: Text -> IO () -> IO (Either GeneratedConfigError ())
ioAttempt operation action = do
    outcome <- try action
    pure $ case outcome of
        Left failure ->
            Left
                ( GeneratedConfigFailure
                    operation
                    (Text.pack (show (failure :: IOError)))
                )
        Right () -> Right ()
