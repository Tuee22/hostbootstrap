{-# LANGUAGE OverloadedStrings #-}

{- | Locked-Origin Identity Ownership for a harness run's generated sibling
@\<project\>.dhall@.

A run generates its own project config, and it must be able to remove /exactly/
the file it installed — never a production config an operator put there, and
never a replacement that appeared under the same name while the run was live.
The predecessor of this module bound a __pathname__: a
@\<config\>.hostbootstrap-test-owner@ __directory__ beside the file, created
with a bare @createDirectory@, holding the payload for a byte comparison at
release.  That is structurally the same design the
@.test_data.hostbootstrap-run-owner@ directory was removed for, and it holds
none of the four clauses of @development_plan_standards.md § EE@: no protected
durable origin record, no stable kernel-identity binding, and no OS-released
lock.  Worse, a crash left the directory behind and the /next/ run refused on
the leftover config before the abandoned-run sweep could resolve it, so the
recovery machinery was unreachable in exactly the case it was built for.

This module is the same four-clause protocol
"HostBootstrap.Harness.DataRoot" holds for the run's data-root directory,
applied to a file:

* __clause 1__ — exclusive entry is the caller's 'ProtectedSession'.  Every
  function here demands one, so observe → record → create → bind (and,
  symmetrically, re-observe → remove) cannot straddle another run's
  transaction, and the kernel releases the lock if this process dies inside the
  bracket;
* __clause 2__ — the durable origin record is published /before/ the first
  mutation, and it names both the recorded absence and the digest of the exact
  payload this run intends to install.  Recording the payload digest before the
  write is what lets recovery distinguish "the file the dead run installed" from
  "a file that appeared afterwards" even when the run died before it could bind
  an identity;
* __clause 3__ — ownership is bound to the created file's own stable kernel
  identity, never to its name;
* __clause 4__ — release re-observes that identity /and/ the payload under the
  same entry, and unlinks the file only when both match exactly.  A replacement,
  an edit, or a vanished file is a structured conflict: nothing is removed, the
  record is retained so the next run's sweep sees the same evidence, and the
  operator's bytes survive.

Unlike the data root, a __found__ object is never adopted and never shared: a
generated config cannot coexist with a config that is already there, so an
occupied path is refused before any record is written and before any mutation.
The authoritative "a production config already exists" refusal therefore belongs
to the harness precondition that runs inside the protected transaction, after
the abandoned-run sweep — not to a bare @doesFileExist@ ahead of it.
-}
module HostBootstrap.Harness.GeneratedConfig (
    -- * The durable origin record (clause 2)
    GeneratedConfigRecord (..),
    encodeGeneratedConfigRecord,
    decodeGeneratedConfigRecord,
    generatedConfigPayloadDigest,

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

import Control.Exception.Safe (finally, mask, onException, try)
import Control.Monad (when)
import qualified Crypto.Hash as Hash
import Data.ByteArray (unpack)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word8)
import HostBootstrap.Config.Install.Native (linkNoReplace)
import HostBootstrap.Harness.Identity (
    IdentityFault (IdentityMalformed, IdentityProbeFailed, IdentityUnsupported),
    ObjectIdentity,
    ObjectIdentityBackend,
    objectIdentityText,
    observeObjectIdentity,
    parseObjectIdentityHex,
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
    doesFileExist,
    removeFile,
 )
import System.FilePath (takeDirectory)
import System.IO (hClose, hFlush, openBinaryTempFile)

-- Identity ------------------------------------------------------------------------

identityFault :: IdentityFault -> GeneratedConfigError
identityFault fault = case fault of
    IdentityUnsupported reason -> GeneratedConfigUnsupported reason
    IdentityProbeFailed operation reason -> GeneratedConfigFailure operation reason
    IdentityMalformed reason -> GeneratedConfigMalformedRecord reason

observeIdentity ::
    ObjectIdentityBackend ->
    FilePath ->
    IO (Either GeneratedConfigError (Maybe ObjectIdentity))
observeIdentity backend path = do
    observed <- observeObjectIdentity backend path
    pure (either (Left . identityFault) Right observed)

parseHexIdentity :: Text -> Either GeneratedConfigError ObjectIdentity
parseHexIdentity = either (Left . identityFault) Right . parseObjectIdentityHex

-- The durable origin record --------------------------------------------------------

{- | The record published before the config file is created.

@'generatedConfigManaged' == Nothing@ is the explicit crash window: the origin
and the intended payload were recorded, but the run died before it could bind
the created file's identity.  Recovery resolves that case from
'generatedConfigPayload' alone, which is why the digest is written first.
-}
data GeneratedConfigRecord = GeneratedConfigRecord
    { generatedConfigPayload :: Text
    , generatedConfigManaged :: Maybe ObjectIdentity
    }
    deriving (Eq, Show)

recordMagic :: ByteString
recordMagic = "hbgc1"

encodeGeneratedConfigRecord :: GeneratedConfigRecord -> ByteString
encodeGeneratedConfigRecord record =
    ByteStringChar8.unlines (recordMagic : originLine : payloadLine : managedLines)
  where
    -- The origin is always an explicit absence: an occupied path is refused
    -- before anything is recorded, so no other prior state can reach a record.
    originLine = "origin absent"
    payloadLine = "payload " <> asciiBytes (generatedConfigPayload record)
    managedLines =
        [ "managed " <> asciiBytes (objectIdentityText identity)
        | Just identity <- [generatedConfigManaged record]
        ]

decodeGeneratedConfigRecord ::
    ByteString ->
    Either GeneratedConfigError GeneratedConfigRecord
decodeGeneratedConfigRecord raw = case ByteStringChar8.lines raw of
    (magic : originLine : payloadLine : rest)
        | magic /= recordMagic ->
            Left (GeneratedConfigMalformedRecord "unknown generated-config record magic")
        | ByteStringChar8.words originLine /= ["origin", "absent"] ->
            Left (GeneratedConfigMalformedRecord "the generated-config origin line is malformed")
        | otherwise -> do
            payload <- decodePayload (ByteStringChar8.words payloadLine)
            managed <- decodeManaged rest
            Right (GeneratedConfigRecord payload managed)
    _ -> Left (GeneratedConfigMalformedRecord "the generated-config record is truncated")
  where
    decodePayload ["payload", encoded]
        | not (ByteString.null encoded) = Right (decodeAscii encoded)
    decodePayload _ =
        Left (GeneratedConfigMalformedRecord "the generated-config payload line is malformed")
    decodeManaged [] = Right Nothing
    decodeManaged [line] = case ByteStringChar8.words line of
        ["managed", encoded] -> Just <$> parseHexIdentity (decodeAscii encoded)
        _ ->
            Left
                (GeneratedConfigMalformedRecord "the generated-config managed line is malformed")
    decodeManaged _ =
        Left
            (GeneratedConfigMalformedRecord "the generated-config record has trailing content")

asciiBytes :: Text -> ByteString
asciiBytes = ByteStringChar8.pack . Text.unpack

decodeAscii :: ByteString -> Text
decodeAscii = Text.pack . ByteStringChar8.unpack

{- | The digest recorded for a payload.  It identifies the bytes without
retaining them, so a config's contents never enter the protected store.
-}
generatedConfigPayloadDigest :: ByteString -> Text
generatedConfigPayloadDigest payload =
    Text.pack (concatMap hex (unpack (Hash.hashWith Hash.SHA256 payload)))
  where
    hex :: Word8 -> String
    hex value = [nibble (value `div` 16), nibble (value `mod` 16)]
    nibble value
        | value < 10 = toEnum (fromEnum '0' + fromIntegral value)
        | otherwise = toEnum (fromEnum 'a' + fromIntegral value - 10)

-- Ownership ------------------------------------------------------------------------

{- | The receipt for one installed generated config.  Its constructor is
private, so it exists only where 'acquireGeneratedConfig' created the file and
bound its identity.  'releaseGeneratedConfig' revalidates the path and record
key it names, so one run's receipt cannot release another's.
-}
data GeneratedConfigOwnership = GeneratedConfigOwnership
    { ownershipPath :: FilePath
    , ownershipKey :: Text
    , ownershipDigest :: Text
    , ownershipManaged :: ObjectIdentity
    }
    deriving (Eq, Show)

generatedConfigOwnershipPath :: GeneratedConfigOwnership -> FilePath
generatedConfigOwnershipPath = ownershipPath

generatedConfigOwnershipDigest :: GeneratedConfigOwnership -> Text
generatedConfigOwnershipDigest = ownershipDigest

generatedConfigOwnershipManaged :: GeneratedConfigOwnership -> ObjectIdentity
generatedConfigOwnershipManaged = ownershipManaged

-- Failures -------------------------------------------------------------------------

data GeneratedConfigError
    = -- | The host cannot supply a stable identity; no receipt is minted.
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

-- Driver ---------------------------------------------------------------------------

{- | Install the run's generated config inside the caller's exclusive entry.

The order is fixed by § EE: observe, publish the origin record naming the
recorded absence and the intended payload digest, only then create the file
create-if-absent, then bind the created file's kernel identity.  An existing
record under this key means a previous incarnation of this exact run did not
settle; that is a conflict for 'recoverGeneratedConfig' to resolve rather than
something to overwrite.
-}
acquireGeneratedConfig ::
    ObjectIdentityBackend ->
    ProtectedSession session ->
    RecordKey ->
    FilePath ->
    -- | the exact bytes to install
    ByteString ->
    IO (Either GeneratedConfigError GeneratedConfigOwnership)
acquireGeneratedConfig backend session key path payload = do
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
                    observed <- observeIdentity backend path
                    case observed of
                        Left failure -> pure (Left failure)
                        -- Never adopted, never replaced, and nothing is
                        -- recorded: the refusal precedes the first mutation.
                        Right (Just _) -> pure (Left (GeneratedConfigOccupied path))
                        Right Nothing -> createUnderRecordedAbsence
  where
    digest = generatedConfigPayloadDigest payload
    createUnderRecordedAbsence = do
        written <-
            compareAndSwapProtectedRecord
                session
                key
                ExpectAbsent
                (encodeGeneratedConfigRecord (GeneratedConfigRecord digest Nothing))
        case written of
            Left failure -> pure (Left (GeneratedConfigStoreFailure failure))
            Right version -> do
                created <- installExclusively path payload
                case created of
                    Left failure -> pure (Left failure)
                    Right () -> do
                        bound <- observeIdentity backend path
                        case bound of
                            Left failure -> pure (Left failure)
                            Right Nothing ->
                                pure
                                    ( Left
                                        ( GeneratedConfigFailure
                                            "bind the generated config identity"
                                            "the file disappeared immediately after creation"
                                        )
                                    )
                            Right (Just identity) -> do
                                confirmed <-
                                    compareAndSwapProtectedRecord
                                        session
                                        key
                                        (ExpectVersion version)
                                        ( encodeGeneratedConfigRecord
                                            (GeneratedConfigRecord digest (Just identity))
                                        )
                                pure $ case confirmed of
                                    Left failure ->
                                        Left (GeneratedConfigStoreFailure failure)
                                    Right _ ->
                                        Right
                                            ( GeneratedConfigOwnership
                                                path
                                                (recordKeyText key)
                                                digest
                                                identity
                                            )

{- | Publish the payload under its final name in one create-if-absent kernel
operation, so a reader never observes a partial file and a taken name fails
rather than being replaced.
-}
installExclusively :: FilePath -> ByteString -> IO (Either GeneratedConfigError ())
installExclusively path payload =
    ioAttempt "install the generated config" $
        mask $ \restore -> do
            (temporary, handle) <-
                openBinaryTempFile (takeDirectory path) ".hostbootstrap-generated.tmp"
            let removeTemporary = do
                    present <- doesFileExist temporary
                    when present (removeFile temporary)
            restore (ByteString.hPut handle payload >> hFlush handle)
                `onException` (hClose handle `finally` removeTemporary)
            hClose handle `onException` removeTemporary
            restore (linkNoReplace temporary path) `finally` removeTemporary

-- | What release did.  Only an exact identity /and/ payload match removes.
data GeneratedConfigRelease = GeneratedConfigRemoved
    deriving (Eq, Show)

{- | Release ownership inside the caller's exclusive entry (clause 4).

The bound identity is re-observed and the bytes are re-hashed; the file is
unlinked only when both match.  A replacement, an edit, or a vanished file is a
structured conflict: nothing is removed and the record is retained, so the next
run's sweep sees exactly the same evidence.
-}
releaseGeneratedConfig ::
    ObjectIdentityBackend ->
    ProtectedSession session ->
    RecordKey ->
    GeneratedConfigOwnership ->
    IO (Either GeneratedConfigError GeneratedConfigRelease)
releaseGeneratedConfig backend session key owned
    | recordKeyText key /= ownershipKey owned =
        pure
            ( Left
                ( GeneratedConfigConflict
                    (Text.pack (ownershipPath owned))
                    ("ownership record " <> ownershipKey owned)
                    ("release attempted under " <> recordKeyText key)
                )
            )
    | otherwise = do
        observed <- observeIdentity backend (ownershipPath owned)
        case observed of
            Left failure -> pure (Left failure)
            Right current -> do
                matched <-
                    matchesOwnedFile
                        (ownershipPath owned)
                        (Just (ownershipManaged owned))
                        current
                        (ownershipDigest owned)
                case matched of
                    Left failure -> pure (Left failure)
                    Right () -> do
                        removed <-
                            ioAttempt
                                "remove the generated config"
                                (removeFile (ownershipPath owned))
                        case removed of
                            Left failure -> pure (Left failure)
                            Right () -> do
                                settled <- deleteRecord session key
                                pure (fmap (const GeneratedConfigRemoved) settled)

{- | What recovery restored for an abandoned run's generated config.  Recovery
never adopts: it removes only the exact file that run installed.
-}
data RecoveredGeneratedConfig
    = -- | The recorded payload was found at the recorded identity and removed.
      GeneratedConfigAbsenceRestored
    | -- | Nothing was at the path; the record is settled.
      GeneratedConfigAlreadyAbsent
    deriving (Eq, Show)

{- | Resolve an abandoned run's generated-config ownership record.

The record is the authority, which is the point of writing it before the first
mutation.  It says the path was __absent__ and names the digest of the payload
the run intended to install, so:

* nothing at the path — the run either never created it or already removed it,
  and the record settles;
* the recorded identity (or, in the crash window before any identity was bound,
  any object) holding exactly the recorded payload — the dead run's own file, so
  absence is restored;
* anything else — a foreign replacement or an edited config, which is refused
  and left intact.

This is what makes an interrupted run's config self-healing instead of an
operator's hand cleanup, and it is only reachable because the existence refusal
now runs /after/ the sweep rather than before it.
-}
recoverGeneratedConfig ::
    ObjectIdentityBackend ->
    ProtectedSession session ->
    RecordKey ->
    FilePath ->
    IO (Either GeneratedConfigError RecoveredGeneratedConfig)
recoverGeneratedConfig backend session key path = do
    stored <- readRecord session key
    case stored of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Right GeneratedConfigAlreadyAbsent)
        Right (Just record) ->
            case decodeGeneratedConfigRecord (protectedRecordBytes record) of
                Left failure -> pure (Left failure)
                Right decoded -> do
                    observed <- observeIdentity backend path
                    case observed of
                        Left failure -> pure (Left failure)
                        Right Nothing -> settle GeneratedConfigAlreadyAbsent
                        Right current -> do
                            matched <-
                                matchesOwnedFile
                                    path
                                    (generatedConfigManaged decoded)
                                    current
                                    (generatedConfigPayload decoded)
                            case matched of
                                Left failure -> pure (Left failure)
                                Right () -> do
                                    removed <-
                                        ioAttempt
                                            "restore the recorded absence of the generated config"
                                            (removeFile path)
                                    case removed of
                                        Left failure -> pure (Left failure)
                                        Right () -> settle GeneratedConfigAbsenceRestored
  where
    settle outcome = do
        deleted <- deleteRecord session key
        pure (fmap (const outcome) deleted)

{- | The shared clause-3 + clause-4 decision: the object at the path must be the
bound one (when an identity was bound at all) /and/ hold exactly the recorded
payload.  Anything else is a conflict and the caller removes nothing.

The @Nothing@ identity case is the explicit crash window between the origin
record and the identity binding.  The payload digest still decides it, so the
window resolves without ever adopting bytes the record does not name.
-}
matchesOwnedFile ::
    FilePath ->
    -- | the identity the record bound, when it got that far
    Maybe ObjectIdentity ->
    -- | the identity observed at the path in this entry
    Maybe ObjectIdentity ->
    -- | the recorded payload digest
    Text ->
    IO (Either GeneratedConfigError ())
matchesOwnedFile path managed current digest
    | Just bound <- managed
    , current /= Just bound =
        pure
            ( Left
                ( GeneratedConfigConflict
                    (Text.pack path)
                    ("identity " <> objectIdentityText bound)
                    (renderObserved current)
                )
            )
    | Nothing <- current =
        pure
            ( Left
                ( GeneratedConfigConflict
                    (Text.pack path)
                    ("payload " <> digest)
                    "absent"
                )
            )
    | otherwise = do
        actual <- ioRead path
        pure $ case actual of
            Left failure -> Left failure
            Right bytes
                | generatedConfigPayloadDigest bytes == digest -> Right ()
                | otherwise ->
                    Left
                        ( GeneratedConfigConflict
                            (Text.pack path)
                            ("payload " <> digest)
                            ("payload " <> generatedConfigPayloadDigest bytes)
                        )

renderObserved :: Maybe ObjectIdentity -> Text
renderObserved Nothing = "absent"
renderObserved (Just identity) = "identity " <> objectIdentityText identity

-- Shared plumbing --------------------------------------------------------------------

readRecord ::
    ProtectedSession session ->
    RecordKey ->
    IO (Either GeneratedConfigError (Maybe ProtectedRecord))
readRecord session key = do
    observed <- readProtectedRecord session key
    pure (either (Left . GeneratedConfigStoreFailure) Right observed)

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

ensureParent :: FilePath -> IO (Either GeneratedConfigError ())
ensureParent path =
    ioAttempt
        "create the generated config's parent directory"
        (createDirectoryIfMissing True (takeDirectory path))

ioRead :: FilePath -> IO (Either GeneratedConfigError ByteString)
ioRead path = do
    outcome <- try (ByteString.readFile path)
    pure $ case outcome of
        Left failure ->
            Left
                ( GeneratedConfigFailure
                    ("read " <> Text.pack path)
                    (Text.pack (show (failure :: IOError)))
                )
        Right bytes -> Right bytes

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
