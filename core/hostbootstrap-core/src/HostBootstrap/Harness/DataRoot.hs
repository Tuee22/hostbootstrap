{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Locked-Origin Identity Ownership for a run's durable data root.

The harness owns @.test_data/\<runId\>@ and must be able to remove /exactly/ the
generation it created without ever removing a directory it merely found. A
recorded "this run created it" boolean is not enough: between creation and
teardown the path can be replaced by another object, and a decision that rests
on the pathname alone would then delete a stranger's directory.

The four clauses of @development_plan_standards.md § EE@ are one transaction and
are written once, in "HostBootstrap.Ownership.Primitive". This module is a
/consumer/ of that seam rather than a second implementation of it: the identity
read, the durable record's encoding, and the identity-conditional act each live
there, and what is here is only the policy that is genuinely the data root's
own.

That policy is three rules:

* the **parent is scaffolding** — @.test_data@ itself is created if missing,
  never owned, and never removed. A run owns its own generation and nothing
  above it;
* a directory the run **merely found** is preserved. The origin record names it,
  no identity is ever bound to it, and § Z's preserve rule is therefore
  structural rather than advisory;
* a generation's **content is this run's own**, so release empties the directory
  after clause 4's re-observation has confirmed the identity and before the seam
  removes it. The order matters: the identity-conditional act stays in the seam,
  and the kernel identity is checked again immediately before listing its
  content. A non-cooperating replacement between that check and the per-entry
  removals remains possible; the protected entry excludes cooperating runs.

Clause 1 is the caller's 'ProtectedSession': every entry point demands one, so
the whole transaction cannot straddle another run's, and the kernel releases the
entry if this process dies inside the bracket. Clause 2's durable record is the
protected store's own compare-and-swap, which is why the seam takes the
publication as a continuation rather than owning a second durable state.

"HostBootstrap.Harness.GeneratedConfig" is the same four-clause protocol over the
run's generated sibling config /file/, through the same seam, so the two cannot
drift.
-}
module HostBootstrap.Harness.DataRoot (
    -- * The durable origin record (clause 2)
    Origin (..),

    -- * Ownership
    DataRootOwnership,
    dataRootOwnershipOrigin,
    dataRootOwnershipManaged,
    dataRootOwnershipPath,

    -- * Driver
    DataRootError (..),
    dataRootErrorMessage,
    acquireDataRoot,
    DataRootRelease (..),
    releaseDataRoot,
    RecoveredDataRoot (..),
    recoverDataRoot,
) where

import Control.Exception.Safe (try)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Harness (selfCreatedTestDataRemoval)
import HostBootstrap.Ownership.Clause (boundEvidence, enteredEvidence, recordedEvidence)
import HostBootstrap.Ownership.Object (
    ConflictReport (..),
    ObjectIdentity,
    ObjectKind (OwnedDirectory),
    Origin (..),
    OwnershipFault (OwnershipConflict, OwnershipOccupied, OwnershipProbeFailed),
    objectIdentityText,
    originRecordBinding,
    originRecordOrigin,
    ownershipFault,
 )
import HostBootstrap.Ownership.Primitive (
    OwnershipRow,
    bindOwnedIdentity,
    createOwnedDirectory,
    enterOwnedObject,
    recordOwnedOrigin,
    reenterStoredOwnedObject,
    releaseOwnedObject,
    reobserveOwnedIdentity,
    rowObserveIdentity,
    rowRemoveObject,
    rowSyncParent,
    withOwnershipRow,
 )
import HostBootstrap.Ownership.Tape (
    OwnershipCarrier (fromClauseFault, fromStoreFault),
    RecordSubject (..),
    RecordTape,
    carryClauseFault,
    forgetRecord,
    publishBoundRecord,
    publishFreshRecord,
    readStoredRecordUnder,
    storedOriginRecord,
    readRawRecordUnder,
    recordTape,
 )
import HostBootstrap.Protected (
    ProtectedError,
    ProtectedSession,
    RecordKey,
    protectedErrorMessage,
    recordKeyText,
 )
import System.Directory (
    createDirectoryIfMissing,
    listDirectory,
    removePathForcibly,
 )
import System.FilePath (takeDirectory, (</>))

-- Ownership --------------------------------------------------------------------

{- | The receipt for one acquired data root. Its constructor is private, so it
exists only where 'acquireDataRoot' bound an identity (or proved the directory
pre-existed). 'releaseDataRoot' compares the supplied record key with the
receipt's key, then uses the receipt's path and the stored record for release.
It does not separately compare a caller-supplied path.
-}
data DataRootOwnership = DataRootOwnership
    { ownershipPath :: FilePath
    , ownershipKey :: Text
    , ownershipOrigin :: Origin
    , ownershipManaged :: Maybe ObjectIdentity
    }
    deriving (Eq, Show)

dataRootOwnershipOrigin :: DataRootOwnership -> Origin
dataRootOwnershipOrigin = ownershipOrigin

{- | The identity this run created, when it created one. 'Nothing' means the
directory pre-existed, so this run owns nothing to remove.
-}
dataRootOwnershipManaged :: DataRootOwnership -> Maybe ObjectIdentity
dataRootOwnershipManaged = ownershipManaged

dataRootOwnershipPath :: DataRootOwnership -> FilePath
dataRootOwnershipPath = ownershipPath

-- Failures ----------------------------------------------------------------------

data DataRootError
    = -- | The host cannot supply a stable identity; no receipt is minted.
      DataRootUnsupported Text
    | -- | The object at the path is not the one ownership names.
      DataRootConflict Text Text Text
    | -- | The durable origin record could not be interpreted.
      DataRootMalformedRecord Text
    | -- | The protected store refused or failed.
      DataRootStoreFailure ProtectedError
    | -- | A filesystem operation failed.
      DataRootFailure Text Text
    deriving (Eq, Show)

dataRootErrorMessage :: DataRootError -> Text
dataRootErrorMessage failure = case failure of
    DataRootUnsupported reason ->
        "the data root cannot be owned on this host: " <> reason
    DataRootConflict path expected observed ->
        "the data root "
            <> path
            <> " is not the object this run owns (expected "
            <> expected
            <> ", observed "
            <> observed
            <> "); it was left intact"
    DataRootMalformedRecord reason ->
        "the data-root ownership record is malformed: " <> reason
    DataRootStoreFailure inner -> protectedErrorMessage inner
    DataRootFailure operation reason ->
        "could not " <> operation <> ": " <> reason

{- | Carry the seam's closed fault sum across into this protocol's vocabulary.

Through the total eliminator, so a case added to the seam's sum is a compile
error here rather than a branch that quietly falls through.
-}
ownershipError :: OwnershipFault -> DataRootError
ownershipError =
    ownershipFault
        DataRootUnsupported
        DataRootFailure
        DataRootMalformedRecord
        (DataRootFailure "own the data root")
        ( \report ->
            DataRootConflict
                (conflictSubject report)
                (renderSide (conflictExpected report))
                (renderSide (conflictObserved report))
        )

renderSide :: Origin -> Text
renderSide OriginAbsent = "absent"
renderSide (OriginPresent identity) = "identity " <> objectIdentityText identity

-- Driver -------------------------------------------------------------------------

{- | Take ownership of the data root inside the caller's exclusive entry.

The order is the seam's, and it is the order § EE states: enter and observe,
publish the origin record, only then create, then bind the created directory's
own kernel identity. An existing record under this key means a previous
incarnation of this exact run did not settle; that is a conflict for
'recoverDataRoot' to resolve rather than something to overwrite.
-}
acquireDataRoot ::
    OwnershipRow ->
    ProtectedSession session ->
    RecordKey ->
    FilePath ->
    IO (Either DataRootError DataRootOwnership)
acquireDataRoot row session key path = do
    existing <- readRawRecordUnder (dataRootTape session) key
    case existing of
        Left failure -> pure (Left failure)
        Right (Just _) ->
            pure
                ( Left
                    ( DataRootConflict
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
                        enterOwnedObject row session path $ \entered -> do
                            recorded <-
                                recordOwnedOrigin row entered OwnedDirectory publishOrigin
                            case recorded of
                                Left fault -> pure (Left fault)
                                Right token ->
                                    recordedEvidence
                                        ( \_target record -> case originRecordOrigin record of
                                            -- Clause 2 for a directory we did not
                                            -- create: the origin names the object we
                                            -- found, and no managed identity is ever
                                            -- bound, so § Z's preserve rule is
                                            -- structural.
                                            found@(OriginPresent _) ->
                                                pure (Right (receipt found Nothing))
                                            OriginAbsent -> createUnderRecordedAbsence token
                                        )
                                        token
                    pure (either (Left . ownershipError) Right outcome)
  where
    createUnderRecordedAbsence token = do
        created <- createOwnedDirectory row token
        case created of
            Left fault@(OwnershipOccupied _) -> do
                forgotten <- forgetRecord (dataRootTape session) key
                pure (either Left (const (Left fault)) forgotten)
            Left fault -> pure (Left fault)
            Right identity -> do
                bound <- bindOwnedIdentity row token identity publishBinding
                pure (fmap (const (receipt OriginAbsent (Just identity))) bound)

    publishOrigin = publishFreshRecord (dataRootTape session) key

    publishBinding = publishBoundRecord (dataRootTape session) key

    receipt origin managed = DataRootOwnership path (recordKeyText key) origin managed

{- | What release did. Both outcomes are successes: a directory this run created
is removed, and one it found is preserved (§ Z).
-}
data DataRootRelease
    = DataRootRemoved
    | DataRootPreserved
    deriving (Eq, Show)

{- | Release ownership inside the caller's exclusive entry (clause 4).

The release re-enters the object through the seam, using the bound record the
store already holds, and the seam re-observes the identity and removes the
directory only on an exact match. A replacement — a different inode at the same
path, or a path that is now absent — is a structured conflict: nothing is
removed and the record is retained so the next run's recovery sees the same
evidence.
-}
releaseDataRoot ::
    OwnershipRow ->
    ProtectedSession session ->
    RecordKey ->
    DataRootOwnership ->
    IO (Either DataRootError DataRootRelease)
releaseDataRoot row session key owned
    | recordKeyText key /= ownershipKey owned =
        pure
            ( Left
                ( DataRootConflict
                    (Text.pack (ownershipPath owned))
                    ("ownership record " <> ownershipKey owned)
                    ("release attempted under " <> recordKeyText key)
                )
            )
    -- The pure § Z guard decides *policy* — a found directory is never in the
    -- removal set — and the seam's identity match decides *authority*.
    | otherwise = case (selfCreatedTestDataRemoval preexisting path, ownershipManaged owned) of
        -- Nothing was created, so there is nothing to remove; ownership of the
        -- found directory simply ends.
        ([], _) -> dropRecord DataRootPreserved
        (_, Nothing) -> dropRecord DataRootPreserved
        (target : _, Just _) -> do
            stored <- readStoredRecordUnder (dataRootTape session) key
            case stored of
                Left failure -> pure (Left failure)
                Right Nothing -> dropRecord DataRootPreserved
                Right (Just record) -> do
                    outcome <-
                        reenterStoredOwnedObject row session target record $ \bound -> do
                            releasable <- reobserveOwnedIdentity row bound
                            case releasable of
                                Left fault -> pure (Left fault)
                                Right token -> do
                                    -- Clause 4 has confirmed this is the directory
                                    -- this run created, so its content is this run's
                                    -- own and is cleared before the seam removes the
                                    -- directory itself.
                                    emptied <-
                                        boundEvidence
                                            (\_ _ identity -> emptyGeneration row target identity)
                                            bound
                                    case emptied of
                                        Left fault -> pure (Left fault)
                                        Right () -> releaseOwnedObject row token forget
                    pure (fmap (const DataRootRemoved) (either (Left . ownershipError) Right outcome))
  where
    path = ownershipPath owned
    preexisting = case ownershipOrigin owned of
        OriginPresent _ -> True
        OriginAbsent -> False
    dropRecord outcome = do
        deleted <- carryClauseFault <$> forgetRecord (dataRootTape session) key
        pure (fmap (const outcome) deleted)
    forget _record = forgetRecord (dataRootTape session) key

{- | What recovery restored for an abandoned run's data root. Recovery never
adopts: it either restores the recorded absence or leaves the recorded
pre-existing object alone.
-}
data RecoveredDataRoot
    = -- | The origin said absent and generated content was removed.
      DataRootAbsenceRestored
    | -- | No record remained, or its directory was authoritatively absent.
      -- The path is not inspected when no record exists.
      DataRootAlreadyAbsent
    | -- | The origin named a pre-existing object, which was left intact.
      DataRootFoundStatePreserved
    deriving (Eq, Show)

{- | Resolve an abandoned run's data-root ownership record.

The record is the authority, which is the point of writing it before the first
mutation. When it says the path was __absent__ and an identity was bound, the
release path above is exactly what recovery runs: re-enter, re-observe, and
remove only on an exact match, so a replacement is refused and left intact.

When it says absent and **no** identity was ever bound, the run died inside the
crash window between clause 2 and clause 3. There is no identity to be
conditional on. Recovery removes only an empty directory, through the row's
non-recursive removal; content cannot be attributed to this run and is a
conflict left intact. An authoritatively absent directory settles either an
unbound or a bound absent-origin record.

When the record says the path was __present__, the object was an operator's and
is never removed, whatever it looks like now.
-}
recoverDataRoot ::
    OwnershipRow ->
    ProtectedSession session ->
    RecordKey ->
    FilePath ->
    IO (Either DataRootError RecoveredDataRoot)
recoverDataRoot row session key path = do
    stored <- readStoredRecordUnder (dataRootTape session) key
    case stored of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Right DataRootAlreadyAbsent)
        Right (Just storedRecord) ->
            let record = storedOriginRecord storedRecord
             in case originRecordOrigin record of
                    OriginPresent _ -> settle DataRootFoundStatePreserved
                    OriginAbsent -> case originRecordBinding record of
                        Just _ -> reclaimBoundGeneration storedRecord
                        Nothing -> restoreRecordedAbsence
  where
    reclaimBoundGeneration record = do
        observed <- enterOwnedObject row session path $ \entered ->
            enteredEvidence
                (\_ origin -> pure (Right origin))
                entered
        case observed of
            Left fault -> pure (Left (ownershipError fault))
            Right OriginAbsent -> settle DataRootAlreadyAbsent
            Right (OriginPresent _) -> do
                outcome <-
                    reenterStoredOwnedObject row session path record $ \bound ->
                        boundEvidence
                            ( \target _record identity -> do
                                releasable <- reobserveOwnedIdentity row bound
                                case releasable of
                                    Left fault -> pure (Left fault)
                                    Right token -> do
                                        emptied <- emptyGeneration row target identity
                                        case emptied of
                                            Left fault -> pure (Left fault)
                                            Right () -> releaseOwnedObject row token forget
                            )
                            bound
                pure (fmap (const DataRootAbsenceRestored) (either (Left . ownershipError) Right outcome))

    restoreRecordedAbsence = do
        outcome <-
            enterOwnedObject row session path $ \entered ->
                enteredEvidence
                    ( \target origin -> case origin of
                        OriginAbsent -> pure (Right DataRootAlreadyAbsent)
                        OriginPresent _ -> do
                            listed <- try (listDirectory target)
                            case listed of
                                Left failure ->
                                    pure
                                        ( Left
                                            ( OwnershipProbeFailed
                                                "inspect the unbound data-root directory"
                                                (Text.pack (show (failure :: IOError)))
                                            )
                                        )
                                Right [] ->
                                    withOwnershipRow row $ \primitives -> do
                                        removed <- rowRemoveObject primitives target
                                        case removed of
                                            Left fault -> pure (Left fault)
                                            Right () -> do
                                                synced <- rowSyncParent primitives target
                                                pure (fmap (const DataRootAbsenceRestored) synced)
                                Right _ ->
                                    pure
                                        ( Left
                                            ( OwnershipConflict
                                                (ConflictReport (Text.pack target) OriginAbsent origin)
                                            )
                                        )
                    )
                    entered
        case outcome of
            Left fault -> pure (Left (ownershipError fault))
            Right restored -> settle restored

    forget _record = forgetRecord (dataRootTape session) key

    settle outcome = do
        deleted <- carryClauseFault <$> forgetRecord (dataRootTape session) key
        pure (fmap (const outcome) deleted)

-- Shared plumbing -----------------------------------------------------------------

{- | What this owner calls its records, for the shared tape's refusals.

The publish, bind, forget and read-back steps are the ones every owner behind
the seam performs; the subject is the only part that is this owner's.
-}
dataRootSubject :: RecordSubject
dataRootSubject =
    RecordSubject
        { subjectRecord = "the data-root origin record"
        , subjectBinding = "bind the data-root identity"
        }

dataRootTape :: ProtectedSession session -> RecordTape session
dataRootTape session = recordTape session dataRootSubject

instance OwnershipCarrier DataRootError where
    fromClauseFault = ownershipError
    fromStoreFault = DataRootStoreFailure

{- | Clear a confirmed generation's own content.

Called after clause 4's re-observation, and checks that same identity again
immediately before listing. A mismatch or disappearance leaves content and
record intact. The check and the per-entry pathname removals are separate
kernel acts: a non-cooperating replacement between them remains possible.
The seam removes the directory itself; clearing its content is owner policy.
-}
emptyGeneration :: OwnershipRow -> FilePath -> ObjectIdentity -> IO (Either OwnershipFault ())
emptyGeneration row target expected =
    withOwnershipRow row $ \primitives -> do
        observed <- rowObserveIdentity primitives target
        case observed of
            Left fault -> pure (Left fault)
            Right current
                | current /= Just expected ->
                    pure
                        ( Left
                            ( OwnershipConflict
                                ( ConflictReport
                                    (Text.pack target)
                                    (OriginPresent expected)
                                    (maybe OriginAbsent OriginPresent current)
                                )
                            )
                        )
                | otherwise -> do
                    outcome <- try $ do
                        entries <- listDirectory target
                        mapM_ (removePathForcibly . (target </>)) entries
                    pure $ case outcome of
                        Left failure ->
                            Left
                                ( OwnershipProbeFailed
                                    "clear the data root's own content"
                                    (Text.pack (show (failure :: IOError)))
                                )
                        Right () -> Right ()

{- | Create the data root's parent, which is ordinary project scaffolding and
not the owned object itself.
-}
ensureParent :: FilePath -> IO (Either DataRootError ())
ensureParent path =
    ioAttempt
        "create the data root's parent directory"
        (createDirectoryIfMissing True (takeDirectory path))

ioAttempt :: Text -> IO () -> IO (Either DataRootError ())
ioAttempt operation action = do
    outcome <- try action
    pure $ case outcome of
        Left failure ->
            Left (DataRootFailure operation (Text.pack (show (failure :: IOError))))
        Right () -> Right ()
