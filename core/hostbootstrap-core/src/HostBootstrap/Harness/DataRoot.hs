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
  and nothing inside the directory is touched until the kernel has confirmed
  that the directory is the one this run created.

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
import HostBootstrap.Ownership.Clause (boundEvidence, recordedEvidence)
import HostBootstrap.Ownership.Object (
    ConflictReport (conflictExpected, conflictObserved, conflictSubject),
    ObjectIdentity,
    ObjectKind (OwnedDirectory),
    Origin (..),
    OriginRecord,
    OwnershipFault (OwnershipProbeFailed),
    objectIdentityText,
    originRecordBinding,
    originRecordOrigin,
    ownershipFault,
    parseOriginRecord,
    renderOriginRecord,
 )
import HostBootstrap.Ownership.Primitive (
    OwnershipRow,
    bindOwnedIdentity,
    createOwnedDirectory,
    enterOwnedObject,
    recordOwnedOrigin,
    reenterOwnedObject,
    releaseOwnedObject,
    reobserveOwnedIdentity,
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
import System.Directory (
    createDirectoryIfMissing,
    listDirectory,
    removePathForcibly,
 )
import System.FilePath (takeDirectory, (</>))

-- Ownership --------------------------------------------------------------------

{- | The receipt for one acquired data root. Its constructor is private, so it
exists only where 'acquireDataRoot' bound an identity (or proved the directory
pre-existed). 'releaseDataRoot' revalidates the path and record key it names, so
a receipt for one run's root cannot release another's.
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
    existing <- readRecord session key
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
            Left fault -> pure (Left fault)
            Right identity -> do
                bound <- bindOwnedIdentity row token identity publishBinding
                pure (fmap (const (receipt OriginAbsent (Just identity))) bound)

    publishOrigin record = do
        written <-
            compareAndSwapProtectedRecord
                session
                key
                ExpectAbsent
                (renderOriginRecord record)
        pure (either (Left . storeFault "publish the data-root origin record") (const (Right ())) written)

    -- The binding is published against the exact version the origin publication
    -- left, read back inside the same exclusive entry. Reading it rather than
    -- carrying it out of the seam's continuation is what keeps the store the one
    -- place a version lives.
    publishBinding record = do
        current <- readProtectedRecord session key
        case current of
            Left failure -> pure (Left (storeFault "read the data-root origin record" failure))
            Right Nothing ->
                pure
                    ( Left
                        ( OwnershipProbeFailed
                            "bind the data-root identity"
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
                        (Left . storeFault "bind the data-root identity")
                        (const (Right ()))
                        written
                    )

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
            stored <- readBoundRecord session key
            case stored of
                Left failure -> pure (Left failure)
                Right Nothing -> dropRecord DataRootPreserved
                Right (Just record) -> do
                    outcome <-
                        reenterOwnedObject row session target record $ \bound -> do
                            releasable <- reobserveOwnedIdentity row bound
                            case releasable of
                                Left fault -> pure (Left fault)
                                Right token -> do
                                    -- Clause 4 has confirmed this is the directory
                                    -- this run created, so its content is this run's
                                    -- own and is cleared before the seam removes the
                                    -- directory itself.
                                    emptied <- emptyGeneration target
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
        deleted <- deleteRecord session key
        pure (fmap (const outcome) deleted)
    forget _record = do
        deleted <- deleteRecord session key
        pure (either (Left . forgetFailure) Right deleted)

{- | What recovery restored for an abandoned run's data root. Recovery never
adopts: it either restores the recorded absence or leaves the recorded
pre-existing object alone.
-}
data RecoveredDataRoot
    = -- | The origin said absent and generated content was removed.
      DataRootAbsenceRestored
    | -- | The origin said absent and the path was already gone.
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
conditional on — that is what the window means — but the record proves that
anything now at the path was generated inside that transaction, so recovery
restores absence rather than adopting the content.

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
    stored <- readRecord session key
    case stored of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Right DataRootAlreadyAbsent)
        Right (Just stamped) -> case parseOriginRecord (protectedRecordBytes stamped) of
            Left fault -> pure (Left (ownershipError fault))
            Right record -> case originRecordOrigin record of
                OriginPresent _ -> settle DataRootFoundStatePreserved
                OriginAbsent -> case originRecordBinding record of
                    Just _ -> reclaimBoundGeneration record
                    Nothing -> restoreRecordedAbsence
  where
    reclaimBoundGeneration record = do
        outcome <-
            reenterOwnedObject row session path record $ \bound ->
                boundEvidence
                    ( \target _record _identity -> do
                        releasable <- reobserveOwnedIdentity row bound
                        case releasable of
                            Left fault -> pure (Left fault)
                            Right token -> do
                                emptied <- emptyGeneration target
                                case emptied of
                                    Left fault -> pure (Left fault)
                                    Right () -> releaseOwnedObject row token forget
                    )
                    bound
        pure (fmap (const DataRootAbsenceRestored) (either (Left . ownershipError) Right outcome))

    restoreRecordedAbsence = do
        removed <-
            ioAttempt
                "restore the recorded absence of the data root"
                (removePathForcibly path)
        case removed of
            Left failure -> pure (Left failure)
            Right () -> settle DataRootAbsenceRestored

    forget _record = do
        deleted <- deleteRecord session key
        pure (either (Left . forgetFailure) Right deleted)

    settle outcome = do
        deleted <- deleteRecord session key
        pure (fmap (const outcome) deleted)

-- Shared plumbing -----------------------------------------------------------------

readRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either DataRootError (Maybe ProtectedRecord))
readRecord session key = do
    observed <- readProtectedRecord session key
    pure (either (Left . DataRootStoreFailure) Right observed)

{- | The durable record, decoded, when one is there. -}
readBoundRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either DataRootError (Maybe OriginRecord))
readBoundRecord session key = do
    stored <- readRecord session key
    pure $ case stored of
        Left failure -> Left failure
        Right Nothing -> Right Nothing
        Right (Just stamped) ->
            either (Left . ownershipError) (Right . Just) (parseOriginRecord (protectedRecordBytes stamped))

{- | Delete the ownership record against the exact version just observed, so a
concurrent writer cannot have its record removed by this settlement.
-}
deleteRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either DataRootError ())
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
            pure (either (Left . DataRootStoreFailure) Right deleted)

{- | Clear a confirmed generation's own content.

Called only after clause 4 has re-observed the identity, so what is emptied is
the directory this run created and never one it found. The seam removes exactly
the named object, which is what keeps it from ever deleting more than it was
asked to; a generation's content is the run's own, so clearing it is this
owner's policy rather than the seam's.
-}
emptyGeneration :: FilePath -> IO (Either OwnershipFault ())
emptyGeneration target = do
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

{- | Carry a store failure into the seam's fault vocabulary.

The seam's publication is a continuation, so a caller's own failure has to be
reported in the seam's terms while it is inside one. The store's exact message
survives; what does not is the structured 'ProtectedError', which no caller of
this module matches on for a publication.
-}
storeFault :: Text -> ProtectedError -> OwnershipFault
storeFault operation failure = OwnershipProbeFailed operation (protectedErrorMessage failure)

forgetFailure :: DataRootError -> OwnershipFault
forgetFailure failure =
    OwnershipProbeFailed "forget the data-root ownership record" (dataRootErrorMessage failure)

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
