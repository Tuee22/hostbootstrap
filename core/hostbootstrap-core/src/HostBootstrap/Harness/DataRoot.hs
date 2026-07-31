{-# LANGUAGE OverloadedStrings #-}

{- | Locked-Origin Identity Ownership for a run's durable data root.

The harness owns @.test_data/\<runId\>@ and must be able to remove /exactly/ the
generation it created without ever removing a directory it merely found.  A
recorded "this run created it" boolean is not enough: between creation and
teardown the path can be replaced by another object, and a decision that rests
on the pathname alone would then delete a stranger's directory.

This module holds all four clauses of @development_plan_standards.md § EE@ for
that directory, with the realization documented in
@documents/architecture/ownership_invariant.md@:

* __clause 1__ — exclusive entry is the caller's 'ProtectedSession'.  Every
  function here demands one, so observe → record → create → bind (and,
  symmetrically, re-observe → remove) cannot straddle another run's
  transaction, and the kernel releases the lock if this process dies inside
  the bracket;
* __clause 2__ — the durable origin record names the exact prior state — the
  identity of an object that was already there, or explicit absence — and is
  published /before/ the first mutation;
* __clause 3__ — ownership is bound to the created directory's stable kernel
  identity ('DataRootIdentity': @device:inode@ on POSIX, volume serial plus
  file index on Windows), never to its name;
* __clause 4__ — release re-observes that identity under the same entry and
  removes the directory only on an exact match.  Any other observation is a
  structured conflict, the directory is left intact, and the receipt is not
  consumed.

A backend that cannot report a stable identity is 'DataRootUnsupported' and
mints no ownership at all, per § EE.  The identity read itself is the injected
'DataRootIdentityBackend' seam, so the whole protocol runs against a real
kernel on every substrate the suite runs on rather than only on one platform
gate.
-}
module HostBootstrap.Harness.DataRoot (
    -- * Stable kernel identity (clause 3)
    DataRootIdentity,
    mkDataRootIdentity,
    dataRootIdentityBytes,
    dataRootIdentityText,
    DataRootIdentityBackend (..),

    -- * The durable origin record (clause 2)
    DataRootOrigin (..),
    encodeDataRootRecord,
    decodeDataRootRecord,

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
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Char (isHexDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word8)
import HostBootstrap.Harness (selfCreatedTestDataRemoval)
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
    createDirectory,
    createDirectoryIfMissing,
    removePathForcibly,
 )
import System.FilePath (takeDirectory)

-- Identity ---------------------------------------------------------------------

{- | A filesystem object's stable kernel identity.  The constructor is private:
a value exists only after a backend read a non-empty identity from the kernel,
so an empty or fabricated identity cannot be compared as though it were one.
-}
newtype DataRootIdentity = DataRootIdentity ByteString
    deriving (Eq, Ord)

instance Show DataRootIdentity where
    show identity = "DataRootIdentity " <> show (dataRootIdentityText identity)

mkDataRootIdentity :: ByteString -> Either DataRootError DataRootIdentity
mkDataRootIdentity raw
    | ByteString.null raw =
        Left (DataRootUnsupported "the host reported an empty data-root identity")
    | ByteString.length raw > 64 =
        Left (DataRootUnsupported "the host reported an over-long data-root identity")
    | otherwise = Right (DataRootIdentity raw)

dataRootIdentityBytes :: DataRootIdentity -> ByteString
dataRootIdentityBytes (DataRootIdentity raw) = raw

-- | The identity as lowercase hex, which is how it is journalled and reported.
dataRootIdentityText :: DataRootIdentity -> Text
dataRootIdentityText (DataRootIdentity raw) =
    Text.pack (concatMap hexByte (ByteString.unpack raw))

hexByte :: Word8 -> String
hexByte value = [hexDigit (value `div` 16), hexDigit (value `mod` 16)]

hexDigit :: Word8 -> Char
hexDigit value
    | value < 10 = toEnum (fromEnum '0' + fromIntegral value)
    | otherwise = toEnum (fromEnum 'a' + fromIntegral value - 10)

parseHexIdentity :: Text -> Either DataRootError DataRootIdentity
parseHexIdentity raw
    | Text.null raw || odd (Text.length raw) || not (Text.all isHexDigit raw) =
        Left (DataRootMalformedRecord ("identity is not lowercase hex: " <> raw))
    | otherwise = mkDataRootIdentity (ByteString.pack (bytes (Text.unpack raw)))
  where
    bytes (high : low : rest) = (nibble high * 16 + nibble low) : bytes rest
    bytes _ = []
    nibble character
        | character >= '0' && character <= '9' =
            fromIntegral (fromEnum character - fromEnum '0')
        | otherwise =
            fromIntegral (fromEnum character - fromEnum 'a' + 10)

{- | How the driver reads a path's stable kernel identity (clause 3).

'Right Nothing' is an authoritative absence; 'Left' is a probe fault, never a
false absence.  Production supplies the native backend; a test injects one that
reports 'DataRootUnsupported' to prove that a host without a stable identity
mints no ownership.
-}
newtype DataRootIdentityBackend = DataRootIdentityBackend
    { observeDataRootIdentity ::
        FilePath ->
        IO (Either DataRootError (Maybe DataRootIdentity))
    }

-- The durable origin record ------------------------------------------------------

{- | The exact prior state of the data root, recorded before the first mutation.

'DataRootOriginPresent' carries the found object's identity so recovery can
tell "the directory an operator left here" from "the directory this run
generated", which is what makes the preserve decision of § Z structural rather
than advisory.
-}
data DataRootOrigin
    = DataRootOriginAbsent
    | DataRootOriginPresent DataRootIdentity
    deriving (Eq, Show)

recordMagic :: ByteString
recordMagic = "hbdr1"

{- | Encode the origin, plus the managed identity once one exists.  The two are
written in two compare-and-swaps — origin before the creation, managed identity
after it — so the crash window is explicit rather than hidden.
-}
encodeDataRootRecord :: DataRootOrigin -> Maybe DataRootIdentity -> ByteString
encodeDataRootRecord origin managed =
    ByteStringChar8.unlines (recordMagic : originLine : managedLines)
  where
    originLine = case origin of
        DataRootOriginAbsent -> "origin absent"
        DataRootOriginPresent identity ->
            "origin present " <> encodeIdentity identity
    managedLines =
        [ "managed " <> encodeIdentity identity
        | Just identity <- [managed]
        ]

encodeIdentity :: DataRootIdentity -> ByteString
encodeIdentity = ByteStringChar8.pack . Text.unpack . dataRootIdentityText

decodeDataRootRecord ::
    ByteString ->
    Either DataRootError (DataRootOrigin, Maybe DataRootIdentity)
decodeDataRootRecord raw = case ByteStringChar8.lines raw of
    (magic : originLine : rest)
        | magic /= recordMagic ->
            Left (DataRootMalformedRecord "unknown data-root record magic")
        | otherwise -> do
            origin <- decodeOrigin (ByteStringChar8.words originLine)
            managed <- decodeManaged rest
            Right (origin, managed)
    _ -> Left (DataRootMalformedRecord "the data-root record is truncated")
  where
    decodeOrigin ["origin", "absent"] = Right DataRootOriginAbsent
    decodeOrigin ["origin", "present", encoded] =
        DataRootOriginPresent <$> parseHexIdentity (decodeAscii encoded)
    decodeOrigin _ =
        Left (DataRootMalformedRecord "the data-root origin line is malformed")
    decodeManaged [] = Right Nothing
    decodeManaged [line] = case ByteStringChar8.words line of
        ["managed", encoded] -> Just <$> parseHexIdentity (decodeAscii encoded)
        _ -> Left (DataRootMalformedRecord "the data-root managed line is malformed")
    decodeManaged _ =
        Left (DataRootMalformedRecord "the data-root record has trailing content")

decodeAscii :: ByteString -> Text
decodeAscii = Text.pack . ByteStringChar8.unpack

-- Ownership --------------------------------------------------------------------

{- | The receipt for one acquired data root.  Its constructor is private, so it
exists only where 'acquireDataRoot' bound an identity (or proved the directory
pre-existed).  'releaseDataRoot' revalidates the path and record key it names,
so a receipt for one run's root cannot release another's.
-}
data DataRootOwnership = DataRootOwnership
    { ownershipPath :: FilePath
    , ownershipKey :: Text
    , ownershipOrigin :: DataRootOrigin
    , ownershipManaged :: Maybe DataRootIdentity
    }
    deriving (Eq, Show)

dataRootOwnershipOrigin :: DataRootOwnership -> DataRootOrigin
dataRootOwnershipOrigin = ownershipOrigin

{- | The identity this run created, when it created one.  'Nothing' means the
directory pre-existed, so this run owns nothing to remove.
-}
dataRootOwnershipManaged :: DataRootOwnership -> Maybe DataRootIdentity
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

-- Driver -------------------------------------------------------------------------

{- | Take ownership of the data root inside the caller's exclusive entry.

The order is fixed by § EE: observe, publish the origin record, only then
create, then bind the created object's kernel identity.  An existing record
under this key means a previous incarnation of this exact run did not settle;
that is a conflict for 'recoverDataRoot' to resolve rather than something to
overwrite.
-}
acquireDataRoot ::
    DataRootIdentityBackend ->
    ProtectedSession session ->
    RecordKey ->
    FilePath ->
    IO (Either DataRootError DataRootOwnership)
acquireDataRoot backend session key path = do
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
                    observed <- observeDataRootIdentity backend path
                    case observed of
                        Left failure -> pure (Left failure)
                        Right (Just found) ->
                            -- Clause 2 for a directory we did not create: the
                            -- origin names the object we found, and no managed
                            -- identity is ever bound, so § Z's preserve rule is
                            -- structural.
                            recordOnly
                                (DataRootOriginPresent found)
                                Nothing
                        Right Nothing -> createUnderRecordedAbsence
  where
    recordOnly origin managed = do
        written <-
            compareAndSwapProtectedRecord
                session
                key
                ExpectAbsent
                (encodeDataRootRecord origin managed)
        pure $ case written of
            Left failure -> Left (DataRootStoreFailure failure)
            Right _ -> Right (ownership origin managed)
    createUnderRecordedAbsence = do
        written <-
            compareAndSwapProtectedRecord
                session
                key
                ExpectAbsent
                (encodeDataRootRecord DataRootOriginAbsent Nothing)
        case written of
            Left failure -> pure (Left (DataRootStoreFailure failure))
            Right version -> do
                created <- ioAttempt "create the data root" (createDirectory path)
                case created of
                    Left failure -> pure (Left failure)
                    Right () -> do
                        bound <- observeDataRootIdentity backend path
                        case bound of
                            Left failure -> pure (Left failure)
                            Right Nothing ->
                                pure
                                    ( Left
                                        ( DataRootFailure
                                            "bind the data root identity"
                                            "the directory disappeared immediately after creation"
                                        )
                                    )
                            Right (Just identity) -> do
                                confirmed <-
                                    compareAndSwapProtectedRecord
                                        session
                                        key
                                        (ExpectVersion version)
                                        ( encodeDataRootRecord
                                            DataRootOriginAbsent
                                            (Just identity)
                                        )
                                pure $ case confirmed of
                                    Left failure -> Left (DataRootStoreFailure failure)
                                    Right _ ->
                                        Right
                                            ( ownership
                                                DataRootOriginAbsent
                                                (Just identity)
                                            )
    ownership origin managed =
        DataRootOwnership path (recordKeyText key) origin managed

{- | What release did.  Both outcomes are successes: a directory this run
created is removed, and one it found is preserved (§ Z).
-}
data DataRootRelease
    = DataRootRemoved
    | DataRootPreserved
    deriving (Eq, Show)

{- | Release ownership inside the caller's exclusive entry (clause 4).

The managed identity is re-observed and the directory is removed only on an
exact match.  A replacement — a different inode at the same path, or a path
that is now absent — is a structured conflict: nothing is removed and the
record is retained so the next run's recovery sees the same evidence.
-}
releaseDataRoot ::
    DataRootIdentityBackend ->
    ProtectedSession session ->
    RecordKey ->
    DataRootOwnership ->
    IO (Either DataRootError DataRootRelease)
releaseDataRoot backend session key owned
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
    -- removal set — and the kernel-identity match below decides *authority*.
    | otherwise = case (selfCreatedTestDataRemoval preexisting path, ownershipManaged owned) of
        -- Nothing was created, so there is nothing to remove; ownership of the
        -- found directory simply ends.
        ([], _) -> dropRecord DataRootPreserved
        (_, Nothing) -> dropRecord DataRootPreserved
        (target : _, Just managed) -> do
            observed <- observeDataRootIdentity backend target
            case observed of
                Left failure -> pure (Left failure)
                Right current
                    | current /= Just managed ->
                        pure (Left (replacement managed current))
                    | otherwise -> do
                        removed <-
                            ioAttempt
                                "remove the data root"
                                (removePathForcibly target)
                        case removed of
                            Left failure -> pure (Left failure)
                            Right () -> dropRecord DataRootRemoved
  where
    path = ownershipPath owned
    preexisting = case ownershipOrigin owned of
        DataRootOriginPresent _ -> True
        DataRootOriginAbsent -> False
    dropRecord outcome = do
        deleted <- deleteRecord session key
        pure (fmap (const outcome) deleted)
    replacement managed current =
        DataRootConflict
            (Text.pack path)
            ("identity " <> dataRootIdentityText managed)
            (renderObserved current)

renderObserved :: Maybe DataRootIdentity -> Text
renderObserved Nothing = "absent"
renderObserved (Just identity) = "identity " <> dataRootIdentityText identity

{- | What recovery restored for an abandoned run's data root.  Recovery never
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
mutation.  When it says the path was __absent__, anything at the path now was
generated inside that run's transaction, so recovery restores absence rather
than adopting the content — including the case where the run died between
publishing the origin and binding the identity, where no managed identity was
ever recorded.  When a managed identity /was/ recorded and the object at the
path is a different one, recovery refuses: the replacement is foreign and is
left intact.

When the record says the path was __present__, the object was an operator's and
is never removed, whatever it looks like now.
-}
recoverDataRoot ::
    DataRootIdentityBackend ->
    ProtectedSession session ->
    RecordKey ->
    FilePath ->
    IO (Either DataRootError RecoveredDataRoot)
recoverDataRoot backend session key path = do
    stored <- readRecord session key
    case stored of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Right DataRootAlreadyAbsent)
        Right (Just record) -> case decodeDataRootRecord (protectedRecordBytes record) of
            Left failure -> pure (Left failure)
            Right (DataRootOriginPresent _, _) ->
                settle DataRootFoundStatePreserved
            Right (DataRootOriginAbsent, managed) -> do
                observed <- observeDataRootIdentity backend path
                case observed of
                    Left failure -> pure (Left failure)
                    Right Nothing -> settle DataRootAlreadyAbsent
                    Right (Just current)
                        | Just recorded <- managed
                        , recorded /= current ->
                            pure
                                ( Left
                                    ( DataRootConflict
                                        (Text.pack path)
                                        ("identity " <> dataRootIdentityText recorded)
                                        ("identity " <> dataRootIdentityText current)
                                    )
                                )
                        | otherwise -> do
                            removed <-
                                ioAttempt
                                    "restore the recorded absence of the data root"
                                    (removePathForcibly path)
                            case removed of
                                Left failure -> pure (Left failure)
                                Right () -> settle DataRootAbsenceRestored
  where
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
