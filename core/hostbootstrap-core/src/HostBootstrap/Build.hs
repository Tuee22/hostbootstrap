{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Build-invocation authority for the in-Dockerfile quality gate (§ X,
the operator-root-and-command-authority phase).

The worked demo installs its canonical config from the
@hostbootstrap-build-config@ BuildKit secret, without @project init@. Its
@check-code@ RUN mounts @hostbootstrap-build-channel@,
@hostbootstrap-build-verification@ and @hostbootstrap-build-coordinator@.
Command supplies those installed inputs, @Context.sourceRoot@ and
@getExecutablePath@ to 'verifyBuildInvocation'.

The build coordinator — the process that decided to build this image — signs a
'BuildBinding' with a long-lived, independently provisioned 'BuildSigningKey'.
The binding names the project, spec digest, config digest, build id, source
digest, and both binary identities. Inside the image, verification:

* takes its verification key from an **installed** file, never from the grant;
* measures the caller-supplied source root and compares it with the signed
  digest, so a grant cannot describe different bytes from the selected tree;
* measures the caller-supplied builder path and compares it, so a grant minted
  for one selected binary cannot authorize another selected binary;
* requires the locally computed Production config digest to match the signed
  one.

Only then does it jointly yield 'ImageBuildFrame' and
'BuildInvocationAuthority', from which the two narrow phase authorities
('CheckCodePhase', 'BuildPhase') are derived. There is no function here that
takes a @BinaryContext@: the baked config cannot reach any of it.

This reusable verifier does not discover that the supplied source root is the
build engine's actual context or that the supplied builder path names the
running executable, and it has no durable replay registry. The concrete Phase
24 command/channel seam must fix those paths from trusted runtime inputs and
consume or durably acknowledge one channel presentation. Within each authority
returned by this verifier, each narrow phase remains at most once.

@ImageBuildScope@ is a build *command* scope, not a third project-secret scope.
The provisioned coordinator signing key remains on the coordinator side, and
the image digest is recorded only after the pre-image, source-bound gate has
already succeeded.
-}
module HostBootstrap.Build (
    -- * The signed binding
    BuildProjectName,
    buildProjectNameFromText,
    buildProjectNameText,
    BuildSpecDigest,
    buildSpecDigestFromText,
    buildSpecDigestText,
    BuildConfigDigest,
    buildConfigDigestFromText,
    buildConfigDigestText,
    BuildIdentifier,
    buildIdentifierFromText,
    buildIdentifierText,
    BuildSourceDigest,
    buildSourceDigestFromText,
    buildSourceDigestText,
    CoordinatorDigest,
    coordinatorDigestFromText,
    coordinatorDigestText,
    BuilderDigest,
    builderDigestFromText,
    builderDigestText,
    BuildFrameName,
    buildFrameNameFromText,
    buildFrameNameText,
    BuildSourceRoot,
    buildSourceRootFromFilePath,
    buildSourceRootFilePath,
    BuilderPath,
    builderPathFromFilePath,
    builderPathFilePath,
    BuildBinding (..),
    renderBuildBinding,

    -- * Independently provisioned build identity
    BuildSigningKey,
    buildSigningKeyFromBytes,
    installedBuildSigningKey,
    BuildVerificationKey,
    buildSigningVerificationKey,
    buildVerificationKeyBytes,
    installedBuildVerificationKey,

    -- * The coordinator side
    BuildCoordinator,
    withBuildCoordinator,
    BuildGrant,
    buildGrantSignature,
    signBuildGrant,

    -- * Measurement
    measureSourceDigest,
    measureBinaryDigest,

    -- * The channel the coordinator delivers over
    BuildChannel (..),
    renderBuildChannel,
    readBuildChannel,

    -- * Verified results
    ImageBuildFrame,
    imageBuildFrameName,
    BuildInvocationAuthority,
    buildAuthorityBuildId,
    buildAuthoritySourceDigest,
    verifyBuildInvocation,

    -- * Narrow phase authority
    BuildPhaseKind (..),
    BuildCommandAuthority,
    buildCommandAuthorityPhase,
    authorizeCheckCode,
    authorizeBuildPhase,

    -- * Failures
    BuildError (..),
    buildErrorMessage,
) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (IOException, evaluate, finally, try)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import qualified Crypto.PubKey.Ed25519 as Ed25519
#ifdef mingw32_HOST_OS
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
#endif
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Char (ord)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
#ifdef mingw32_HOST_OS
import Data.Word (Word8)
#endif
import HostBootstrap.Digest (sha256Hex)
import HostBootstrap.Handoff (
    HandoffError (HandoffWireTruncated),
    frameWire,
    handoffErrorMessage,
    takeHandoffFrame,
    unframeWire,
 )
import System.Directory (doesFileExist)
import qualified System.Directory.OsPath as OsDirectory
import qualified System.File.OsPath as OsFile
import qualified System.OsPath as OsPath
#ifdef mingw32_HOST_OS
import qualified System.Directory.Internal as DirectoryInternal
import qualified System.Win32.WindowsString.File as Win32
#else
import qualified System.Posix.Files.ByteString as PosixFiles
#endif

-- ---------------------------------------------------------------------------
-- Bindings

-- | A descriptive project coordinate, with no added validity or authority claim.
newtype BuildProjectName = BuildProjectName Text
    deriving (Eq)

instance Show BuildProjectName where
    showsPrec precedence (BuildProjectName value) = showsPrec precedence value

-- | Assign the build-project role without imposing a new text format.
buildProjectNameFromText :: Text -> BuildProjectName
buildProjectNameFromText = BuildProjectName

-- | Read the descriptive project text.
buildProjectNameText :: BuildProjectName -> Text
buildProjectNameText (BuildProjectName value) = value

-- | A descriptive specification coordinate, with no new validity or authority claim.
newtype BuildSpecDigest = BuildSpecDigest Text
    deriving (Eq)

instance Show BuildSpecDigest where
    showsPrec precedence (BuildSpecDigest value) = showsPrec precedence value

-- | Assign the build-specification role without imposing a new text format.
buildSpecDigestFromText :: Text -> BuildSpecDigest
buildSpecDigestFromText = BuildSpecDigest

-- | Read the descriptive specification text.
buildSpecDigestText :: BuildSpecDigest -> Text
buildSpecDigestText (BuildSpecDigest value) = value

-- | A descriptive config coordinate, with no new validity or authority claim.
newtype BuildConfigDigest = BuildConfigDigest Text
    deriving (Eq)

instance Show BuildConfigDigest where
    showsPrec precedence (BuildConfigDigest value) = showsPrec precedence value

-- | Assign the build-config role without imposing a new text format.
buildConfigDigestFromText :: Text -> BuildConfigDigest
buildConfigDigestFromText = BuildConfigDigest

-- | Read the descriptive config text.
buildConfigDigestText :: BuildConfigDigest -> Text
buildConfigDigestText (BuildConfigDigest value) = value

-- | A descriptive build identifier; validity remains a verifier requirement.
newtype BuildIdentifier = BuildIdentifier Text
    deriving (Eq)

instance Show BuildIdentifier where
    showsPrec precedence (BuildIdentifier value) = showsPrec precedence value

-- | Assign the identifier role without moving the existing nonempty check.
buildIdentifierFromText :: Text -> BuildIdentifier
buildIdentifierFromText = BuildIdentifier

-- | Read the descriptive build identifier.
buildIdentifierText :: BuildIdentifier -> Text
buildIdentifierText (BuildIdentifier value) = value

-- | A descriptive source digest; fresh measurement remains a verifier requirement.
newtype BuildSourceDigest = BuildSourceDigest Text
    deriving (Eq)

instance Show BuildSourceDigest where
    showsPrec precedence (BuildSourceDigest value) = showsPrec precedence value

-- | Assign the descriptive role without adding format or provenance checks.
buildSourceDigestFromText :: Text -> BuildSourceDigest
buildSourceDigestFromText = BuildSourceDigest

-- | Read the existing descriptive text.
buildSourceDigestText :: BuildSourceDigest -> Text
buildSourceDigestText (BuildSourceDigest value) = value

-- | A descriptive coordinator digest; trust remains at the signing boundary.
newtype CoordinatorDigest = CoordinatorDigest Text
    deriving (Eq)

instance Show CoordinatorDigest where
    showsPrec precedence (CoordinatorDigest value) = showsPrec precedence value

-- | Assign the role without adding format, validity or provenance checks.
coordinatorDigestFromText :: Text -> CoordinatorDigest
coordinatorDigestFromText = CoordinatorDigest

-- | Read the existing descriptive coordinator text.
coordinatorDigestText :: CoordinatorDigest -> Text
coordinatorDigestText (CoordinatorDigest value) = value

-- | A descriptive builder digest; fresh binary measurement remains required.
newtype BuilderDigest = BuilderDigest Text
    deriving (Eq)

instance Show BuilderDigest where
    showsPrec precedence (BuilderDigest value) = showsPrec precedence value

-- | Assign the role without adding format, validity or provenance checks.
builderDigestFromText :: Text -> BuilderDigest
builderDigestFromText = BuilderDigest

-- | Read the existing descriptive builder text.
builderDigestText :: BuilderDigest -> Text
builderDigestText (BuilderDigest value) = value

-- | A descriptive frame name; nonempty validation remains at verification.
newtype BuildFrameName = BuildFrameName Text
    deriving (Eq)

instance Show BuildFrameName where
    showsPrec precedence (BuildFrameName value) = showsPrec precedence value

-- | Assign the role without moving the existing nonempty-frame check.
buildFrameNameFromText :: Text -> BuildFrameName
buildFrameNameFromText = BuildFrameName

-- | Read the existing descriptive frame text.
buildFrameNameText :: BuildFrameName -> Text
buildFrameNameText (BuildFrameName value) = value

-- | A descriptive source root; filesystem measurement remains a verifier task.
newtype BuildSourceRoot = BuildSourceRoot FilePath
    deriving (Eq)

instance Show BuildSourceRoot where
    showsPrec precedence (BuildSourceRoot value) = showsPrec precedence value

-- | Assign the role without validation, normalization or provenance checks.
buildSourceRootFromFilePath :: FilePath -> BuildSourceRoot
buildSourceRootFromFilePath = BuildSourceRoot

-- | Read the existing source-root path.
buildSourceRootFilePath :: BuildSourceRoot -> FilePath
buildSourceRootFilePath (BuildSourceRoot value) = value

-- | A descriptive builder path; binary measurement remains a verifier task.
newtype BuilderPath = BuilderPath FilePath
    deriving (Eq)

instance Show BuilderPath where
    showsPrec precedence (BuilderPath value) = showsPrec precedence value

-- | Assign the role without validation, normalization or provenance checks.
builderPathFromFilePath :: FilePath -> BuilderPath
builderPathFromFilePath = BuilderPath

-- | Read the existing builder path.
builderPathFilePath :: BuilderPath -> FilePath
builderPathFilePath (BuilderPath value) = value

{- | Everything a build grant authenticates.

The two binary digests are separate on purpose: the **coordinator** is the
process that decided to build, and the **builder** is the binary that will run
the gate inside the image. A grant issued for one builder cannot authorize a
different one even when everything else matches.
-}
data BuildBinding = BuildBinding
    { buildProjectName :: BuildProjectName
    , buildSpecDigest :: BuildSpecDigest
    , buildConfigDigest :: BuildConfigDigest
    , buildIdentifier :: BuildIdentifier
    , buildSourceDigest :: BuildSourceDigest
    , buildCoordinatorDigest :: CoordinatorDigest
    , buildBuilderDigest :: BuilderDigest
    , buildFrameName :: BuildFrameName
    }
    deriving (Eq, Show)

-- | Canonical bytes, length-prefixed per field so no two bindings collide.
renderBuildBinding :: BuildBinding -> ByteString
renderBuildBinding binding =
    ByteString.concat
        [ field (buildProjectNameText (buildProjectName binding))
        , field (buildSpecDigestText (buildSpecDigest binding))
        , field (buildConfigDigestText (buildConfigDigest binding))
        , field (buildIdentifierText (buildIdentifier binding))
        , field (buildSourceDigestText (buildSourceDigest binding))
        , field (coordinatorDigestText (buildCoordinatorDigest binding))
        , field (builderDigestText (buildBuilderDigest binding))
        , field (buildFrameNameText (buildFrameName binding))
        ]
  where
    field = frameWire . TextEncoding.encodeUtf8

-- ---------------------------------------------------------------------------
-- Provisioned keys and coordinator

{- | The root-side, long-lived build signing identity.

The constructor and secret bytes are hidden. Provisioning may validate an
Ed25519 seed directly or load one from a protected file. The corresponding
'BuildVerificationKey' is derived before any coordinator bracket begins, so an
image never has to ask a live coordinator which key should verify its grant.
-}
newtype BuildSigningKey = BuildSigningKey Ed25519.SecretKey

instance Show BuildSigningKey where
    show _ = "BuildSigningKey <redacted>"

-- | Validate a provisioned 32-byte Ed25519 signing seed.
buildSigningKeyFromBytes :: ByteString -> Either BuildError BuildSigningKey
buildSigningKeyFromBytes raw = case Ed25519.secretKey raw of
    CryptoFailed err -> Left (BuildSigningKeyInvalid (Text.pack (show err)))
    CryptoPassed key -> Right (BuildSigningKey key)

-- | Load and validate the coordinator's provisioned signing seed.
installedBuildSigningKey :: FilePath -> IO (Either BuildError BuildSigningKey)
installedBuildSigningKey path =
    loadBuildKey
        BuildSigningKeyUnavailable
        buildSigningKeyFromBytes
        path

{- | The independently installed public half of the build signing identity.

Its constructor is hidden. The coordinator side derives bytes for provisioning;
the image side obtains the value only by loading and validating its installed
public-key file.
-}
newtype BuildVerificationKey = BuildVerificationKey Ed25519.PublicKey
    deriving (Eq)

instance Show BuildVerificationKey where
    show _ = "BuildVerificationKey <installed>"

-- | Derive the public half for installation before a coordinator is opened.
buildSigningVerificationKey :: BuildSigningKey -> BuildVerificationKey
buildSigningVerificationKey (BuildSigningKey secret) =
    BuildVerificationKey (Ed25519.toPublic secret)

-- | Public bytes used only to provision the image's independent key file.
buildVerificationKeyBytes :: BuildVerificationKey -> ByteString
buildVerificationKeyBytes (BuildVerificationKey key) = convert key

-- | Load and validate the public key independently installed in the image.
installedBuildVerificationKey :: FilePath -> IO (Either BuildError BuildVerificationKey)
installedBuildVerificationKey path =
    loadBuildKey
        BuildVerificationKeyUnavailable
        parseBuildVerificationKey
        path

parseBuildVerificationKey :: ByteString -> Either BuildError BuildVerificationKey
parseBuildVerificationKey raw = case Ed25519.publicKey raw of
    CryptoFailed err -> Left (BuildVerificationKeyInvalid (Text.pack (show err)))
    CryptoPassed key -> Right (BuildVerificationKey key)

loadBuildKey ::
    (Text -> BuildError) ->
    (ByteString -> Either BuildError key) ->
    FilePath ->
    IO (Either BuildError key)
loadBuildKey unavailable parseKey path = do
    present <- doesFileExist path
    if not present
        then pure (Left (unavailable ("no installed key at " <> Text.pack path)))
        else do
            loaded <- try (ByteString.readFile path) :: IO (Either IOException ByteString)
            pure $ case loaded of
                Left err ->
                    Left
                        ( unavailable
                            ("failed to read " <> Text.pack path <> ": " <> Text.pack (firstLine (show err)))
                        )
                Right raw -> parseKey raw

{- | One active use of the provisioned signing identity.

The fresh nominal @coordinatorId@ prevents ordinary escape. The active-state
lock additionally refuses an existentially retained coordinator after the
callback ends. Signing holds that same lock for the whole operation, so cleanup
cannot mark the bracket closed while a signature is still being produced.
-}
data BuildCoordinator coordinatorId = BuildCoordinator
    { coordinatorSigningKey :: BuildSigningKey
    , coordinatorDigest :: CoordinatorDigest
    , coordinatorActive :: MVar Bool
    }

type role BuildCoordinator nominal

instance Show (BuildCoordinator coordinatorId) where
    show coordinator = "BuildCoordinator <signing> " <> Text.unpack (coordinatorDigestText (coordinatorDigest coordinator))

{- | Run an action with one active use of the provisioned signing key, bound to
the coordinator binary's measured digest.
-}
withBuildCoordinator ::
    BuildSigningKey ->
    -- | the coordinator binary's measured digest
    CoordinatorDigest ->
    (forall coordinatorId. BuildCoordinator coordinatorId -> IO result) ->
    IO result
withBuildCoordinator signingKey digest use = do
    active <- newMVar True
    use
        BuildCoordinator
            { coordinatorSigningKey = signingKey
            , coordinatorDigest = digest
            , coordinatorActive = active
            }
        `finally` modifyMVar_ active (const (pure False))

-- | The coordinator's signature over one binding.
newtype BuildGrant = BuildGrant ByteString
    deriving (Eq)

instance Show BuildGrant where
    show _ = "BuildGrant <signed>"

buildGrantSignature :: BuildGrant -> ByteString
buildGrantSignature (BuildGrant value) = value

{- | Sign a build grant. The coordinator refuses a binding that names a
different coordinator than itself, so it cannot be used to mint grants
attributed to another build authority.
-}
signBuildGrant :: BuildCoordinator coordinatorId -> BuildBinding -> IO (Either BuildError BuildGrant)
signBuildGrant coordinator binding =
    withMVar (coordinatorActive coordinator) $ \active ->
        if not active
            then pure (Left BuildCoordinatorExpired)
            else
                if buildCoordinatorDigest binding /= coordinatorDigest coordinator
                    then
                        pure
                            ( Left
                                ( BuildIdentityMismatch
                                    "coordinator"
                                    (coordinatorDigestText (buildCoordinatorDigest binding))
                                    (coordinatorDigestText (coordinatorDigest coordinator))
                                )
                            )
                    else Right <$> signBinding (coordinatorSigningKey coordinator) binding

signBinding :: BuildSigningKey -> BuildBinding -> IO BuildGrant
signBinding (BuildSigningKey secret) binding = do
    let signature :: ByteString
        signature =
            convert
                ( Ed25519.sign
                    secret
                    (Ed25519.toPublic secret)
                    (buildSignedMaterial binding)
                )
    -- Force the strict signature bytes while the active-state MVar is held.
    -- Otherwise the pure cryptographic thunk could be evaluated after cleanup.
    _ <- evaluate (ByteString.length signature)
    pure (BuildGrant signature)

buildGrantDomain :: ByteString
buildGrantDomain = "hostbootstrap/build/v1"

buildSignedMaterial :: BuildBinding -> ByteString
buildSignedMaterial binding =
    frameWire buildGrantDomain <> frameWire (renderBuildBinding binding)

-- ---------------------------------------------------------------------------
-- Measurement

{- | Hash regular-file relative names and strict content bytes under the supplied
root. POSIX names retain their exact bytes; Windows UTF-16 names use UTF-8 with
unpaired units preserved as WTF-8. Components join with one slash byte, entries
sort by those canonical relative-name bytes, and both names and contents retain
the existing length framing. The absolute root, locale, modes, empty directories
and whether regular contents came through a symlink or a copy are excluded.

A missing root or non-regular source entry is a typed refusal. Only filesystem
IO exceptions become measurement failures; asynchronous cancellation propagates.
-}
measureSourceDigest :: FilePath -> IO (Either BuildError Text)
measureSourceDigest root = do
    measured <- try measure :: IO (Either IOException (Either BuildError Text))
    pure $ case measured of
        Left failure -> Left (BuildSourceUnavailable (Text.pack (root <> ": " <> firstLine (show failure))))
        Right outcome -> outcome
  where
    measure = do
        nativeRoot <- OsPath.encodeFS root
        present <- OsDirectory.doesDirectoryExist nativeRoot
        if not present
            then pure (Left (BuildSourceUnavailable (Text.pack root)))
            else do
                collected <- collect ByteString.empty nativeRoot
                pure $
                    fmap
                        ( sha256Hex
                            . ByteString.concat
                            . map (\(name, contents) -> frameWire name <> frameWire contents)
                            . sort
                        )
                        collected
    collect prefix directory = do
        names <- OsDirectory.listDirectory directory
        nested <- traverse (visit prefix directory) names
        pure (concat <$> sequence nested)
    visit prefix directory name = do
        let absolute = directory OsPath.</> name
            component = canonicalSourceNameBytes name
            relative = if ByteString.null prefix then component else prefix <> "/" <> component
        (isDirectory, isRegular) <- sourcePathKind absolute
        if isDirectory
            then collect relative absolute
            else
                if isRegular
                    then do
                        contents <- OsFile.readFile' absolute
                        pure (Right [(relative, contents)])
                    else pure (Left (BuildSourceUnavailable ("non-regular source entry: " <> Text.pack (show relative))))

-- | Digest only a regular builder/coordinator file. Metadata is read before
-- file contents, so a FIFO or device cannot block a measurement read.
measureBinaryDigest :: FilePath -> IO (Either BuildError Text)
measureBinaryDigest path = do
    measured <- try measure :: IO (Either IOException (Either BuildError Text))
    pure $ case measured of
        Left failure -> Left (BuildBinaryUnavailable (Text.pack (path <> ": " <> firstLine (show failure))))
        Right outcome -> outcome
  where
    measure = do
        nativePath <- OsPath.encodeFS path
        present <- OsDirectory.doesPathExist nativePath
        if not present
            then pure (Left (BuildBinaryUnavailable (Text.pack path)))
            else do
                (_, isRegular) <- sourcePathKind nativePath
                if isRegular
                    then Right . sha256Hex <$> OsFile.readFile' nativePath
                    else pure (Left (BuildBinaryUnavailable ("non-regular binary path: " <> Text.pack path)))

-- | Directory and regular-file classification without a content read.
sourcePathKind :: OsPath.OsPath -> IO (Bool, Bool)
#ifdef mingw32_HOST_OS
sourcePathKind path = do
    native <- DirectoryInternal.furnishPath path
    attributes <- Win32.fadFileAttributes <$> Win32.getFileAttributesExStandard native
    let directory = attributes .&. Win32.fILE_ATTRIBUTE_DIRECTORY /= 0
        -- FILE_ATTRIBUTE_DEVICE is the reserved device attribute, value 0x40.
        device = attributes .&. 0x40 /= 0
    pure (directory, not directory && not device)
#else
sourcePathKind path = do
    status <- PosixFiles.getFileStatus (canonicalSourceNameBytes path)
    pure (PosixFiles.isDirectory status, PosixFiles.isRegularFile status)
#endif

-- | Encode actual native name units without a locale/text round trip.
canonicalSourceNameBytes :: OsPath.OsPath -> ByteString
#ifdef mingw32_HOST_OS
canonicalSourceNameBytes =
    ByteString.pack . encodeUnits . map (ord . OsPath.toChar) . OsPath.unpack
  where
    encodeUnits (high : low : rest)
        | high >= 0xd800 && high <= 0xdbff && low >= 0xdc00 && low <= 0xdfff =
            utf8 (0x10000 + ((high - 0xd800) `shiftL` 10) + low - 0xdc00) <> encodeUnits rest
    encodeUnits (unit : rest) = utf8 unit <> encodeUnits rest
    encodeUnits [] = []
    utf8 :: Int -> [Word8]
    utf8 unit
        | unit <= 0x7f = [fromIntegral unit]
        | unit <= 0x7ff =
            [ fromIntegral (0xc0 .|. (unit `shiftR` 6))
            , continuation unit
            ]
        | unit <= 0xffff =
            [ fromIntegral (0xe0 .|. (unit `shiftR` 12))
            , continuation (unit `shiftR` 6)
            , continuation unit
            ]
        | otherwise =
            [ fromIntegral (0xf0 .|. (unit `shiftR` 18))
            , continuation (unit `shiftR` 12)
            , continuation (unit `shiftR` 6)
            , continuation unit
            ]
    continuation unit = fromIntegral (0x80 .|. (unit .&. 0x3f))
#else
canonicalSourceNameBytes = ByteString.pack . map (fromIntegral . ord . OsPath.toChar) . OsPath.unpack
#endif

-- ---------------------------------------------------------------------------
-- The delivery channel

{- | What the coordinator delivers into the build: the binding and its grant.

Delivered over the build engine's secret/session channel — a file the build
mounts, not @argv@ or the environment. An absent channel is
'BuildChannelUnavailable', which is the honest answer for a build backend that
has no such channel at all: the gate refuses rather than falling back to the
baked config.
-}
data BuildChannel = BuildChannel
    { channelBinding :: BuildBinding
    , channelGrant :: BuildGrant
    }
    deriving (Eq, Show)

{- | The wire a coordinator writes: the eight binding fields then the signature,
each length-delimited.
-}
renderBuildChannel :: BuildChannel -> ByteString
renderBuildChannel channel =
    renderBuildBinding (channelBinding channel)
        <> frameWire (buildGrantSignature (channelGrant channel))

{- | Read a delivered channel. The wire is nine length-delimited frames: the
eight binding fields then the signature.
-}
readBuildChannel :: FilePath -> IO (Either BuildError BuildChannel)
readBuildChannel path = do
    present <- doesFileExist path
    if not present
        then pure (Left (BuildChannelUnavailable (Text.pack path)))
        else do
            loaded <- try (ByteString.readFile path) :: IO (Either IOException ByteString)
            pure $ case loaded of
                Left err ->
                    Left (BuildChannelUnavailable (Text.pack (path <> ": " <> firstLine (show err))))
                Right raw -> decodeChannel raw

decodeChannel :: ByteString -> Either BuildError BuildChannel
decodeChannel raw = do
    (fields, signature) <- takeFrames 8 raw
    case fields of
        [project, spec, config, buildId, source, coordinator, builder, frame] -> do
            texts <-
                traverse
                    decodeUtf8Field
                    [project, spec, config, buildId, source, coordinator, builder, frame]
            case texts of
                [p, sp, c, b, so, co, bu, f] ->
                    Right
                        BuildChannel
                            { channelBinding =
                                BuildBinding
                                    { buildProjectName = buildProjectNameFromText p
                                    , buildSpecDigest = buildSpecDigestFromText sp
                                    , buildConfigDigest = buildConfigDigestFromText c
                                    , buildIdentifier = buildIdentifierFromText b
                                    , buildSourceDigest = buildSourceDigestFromText so
                                    , buildCoordinatorDigest = coordinatorDigestFromText co
                                    , buildBuilderDigest = builderDigestFromText bu
                                    , buildFrameName = buildFrameNameFromText f
                                    }
                            , channelGrant = BuildGrant signature
                            }
                _ -> Left (BuildChannelMalformed "unexpected field count")
        _ -> Left (BuildChannelMalformed "unexpected field count")

{- | Split the leading @count@ length-delimited frames off the wire, then require
the remainder to be exactly one more frame (the signature). Trailing bytes after
it are refused rather than ignored.
-}
takeFrames :: Int -> ByteString -> Either BuildError ([ByteString], ByteString)
takeFrames count raw = go count raw []
  where
    go 0 rest acc = case unframeWire rest of
        Left _ -> Left (BuildChannelMalformed "missing or malformed signature frame")
        Right signature -> Right (reverse acc, signature)
    go remaining rest acc = case takeHandoffFrame rest of
        Left (HandoffWireTruncated {})
            | ByteString.length rest < 8 -> Left (BuildChannelMalformed "truncated channel")
            | otherwise -> Left (BuildChannelMalformed "truncated channel field")
        Left failure -> Left (BuildChannelMalformed (Text.pack (handoffErrorMessage failure)))
        Right (field, suffix) -> go (remaining - 1) suffix (field : acc)

decodeUtf8Field :: ByteString -> Either BuildError Text
decodeUtf8Field raw = case TextEncoding.decodeUtf8' raw of
    Left _ -> Left (BuildChannelMalformed "a channel field is not valid UTF-8")
    Right value -> Right value

-- ---------------------------------------------------------------------------
-- Verified results

{- | The frame an authenticated build runs in. Jointly minted with the
authority, so a caller cannot pair a frame from one build with authority from
another.
-}
data ImageBuildFrame projectId specDigest configId frame = ImageBuildFrame BuildFrameName

type role ImageBuildFrame nominal nominal nominal nominal

instance Show (ImageBuildFrame projectId specDigest configId frame) where
    show (ImageBuildFrame name) = "ImageBuildFrame " <> Text.unpack (buildFrameNameText name)

imageBuildFrameName :: ImageBuildFrame projectId specDigest configId frame -> Text
imageBuildFrameName (ImageBuildFrame name) = buildFrameNameText name

{- | Ephemeral authority for one successful verification result. Opaque: it
exists only as a result of 'verifyBuildInvocation'. Each result owns its own
in-memory phase-consumption state; cross-presentation replay belongs to the
concrete command/channel consumer.
-}
data BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest
    = BuildInvocationAuthority BuildIdentifier BuildSourceDigest (IORef [BuildPhaseKind])

type role BuildInvocationAuthority nominal nominal nominal nominal nominal nominal

instance Show (BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest) where
    show (BuildInvocationAuthority buildId _ _) = "BuildInvocationAuthority " <> Text.unpack (buildIdentifierText buildId)

buildAuthorityBuildId ::
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest -> Text
buildAuthorityBuildId (BuildInvocationAuthority value _ _) = buildIdentifierText value

buildAuthoritySourceDigest ::
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest -> Text
buildAuthoritySourceDigest (BuildInvocationAuthority _ value _) = buildSourceDigestText value

{- | Verify a delivered build channel inside the image.

Every comparison is against something measured or computed outside the grant,
never against a value the grant supplies about itself. The verification key is
an installed input; the source and builder digests are measured from the two
paths supplied by the caller; and the config digest is the one the caller
computed through the Production project codec. This primitive does not prove
that those paths are the build engine's actual context or the running
executable. The fixed consumer seam must derive them from trusted runtime
inputs and separately enforce single presentation or durable @buildId@ replay
refusal.
-}
verifyBuildInvocation ::
    -- | the installed verification key
    BuildVerificationKey ->
    -- | the locally verified project name
    BuildProjectName ->
    -- | the finalized Production codec's locally computed spec digest
    BuildSpecDigest ->
    -- | the locally computed Production config digest
    BuildConfigDigest ->
    -- | the installed coordinator binary identity
    CoordinatorDigest ->
    -- | the caller-selected source root to measure
    BuildSourceRoot ->
    -- | the caller-selected builder path to measure
    BuilderPath ->
    BuildChannel ->
    ( forall projectId specDigest configId frame buildId sourceDigest builderBinaryDigest.
      ImageBuildFrame projectId specDigest configId frame ->
      BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest ->
      IO result
    ) ->
    IO
        ( Either
            BuildError
            result
        )
verifyBuildInvocation key projectName specDigest configDigest expectedCoordinator sourceRoot builderPath channel use
    | buildProjectName binding /= projectName =
        pure
            ( Left
                ( BuildIdentityMismatch
                    "project"
                    (buildProjectNameText (buildProjectName binding))
                    (buildProjectNameText projectName)
                )
            )
    | buildSpecDigest binding /= specDigest =
        pure
            ( Left
                ( BuildIdentityMismatch
                    "spec digest"
                    (buildSpecDigestText (buildSpecDigest binding))
                    (buildSpecDigestText specDigest)
                )
            )
    | buildConfigDigest binding /= configDigest =
        pure
            ( Left
                ( BuildIdentityMismatch
                    "config digest"
                    (buildConfigDigestText (buildConfigDigest binding))
                    (buildConfigDigestText configDigest)
                )
            )
    | buildCoordinatorDigest binding /= expectedCoordinator =
        pure
            ( Left
                ( BuildIdentityMismatch
                    "coordinator binary"
                    (coordinatorDigestText (buildCoordinatorDigest binding))
                    (coordinatorDigestText expectedCoordinator)
                )
            )
    | Text.null (buildIdentifierText (buildIdentifier binding)) =
        pure (Left (BuildChannelMalformed "the build id is empty"))
    | Text.null (buildFrameNameText (buildFrameName binding)) =
        pure (Left (BuildChannelMalformed "the image-build frame is empty"))
    | otherwise = do
        measuredSource <- fmap buildSourceDigestFromText <$> measureSourceDigest (buildSourceRootFilePath sourceRoot)
        case measuredSource of
            Left failure -> pure (Left failure)
            Right actualSource
                | buildSourceDigest binding /= actualSource ->
                    pure
                        ( Left
                            (BuildIdentityMismatch "source digest" (buildSourceDigestText (buildSourceDigest binding)) (buildSourceDigestText actualSource))
                        )
                | otherwise -> do
                    measuredBuilder <- fmap builderDigestFromText <$> measureBinaryDigest (builderPathFilePath builderPath)
                    case measuredBuilder of
                        Left failure -> pure (Left failure)
                        Right actualBuilder
                            | buildBuilderDigest binding /= actualBuilder ->
                                pure
                                    ( Left
                                        ( BuildIdentityMismatch
                                            "builder binary"
                                            (builderDigestText (buildBuilderDigest binding))
                                            (builderDigestText actualBuilder)
                                        )
                                    )
                            | otherwise -> checkSignature actualSource
  where
    binding = channelBinding channel
    BuildGrant signature = channelGrant channel

    checkSignature actualSource = case Ed25519.signature signature of
        CryptoFailed err -> pure (Left (BuildSignatureInvalid (Text.pack (show err))))
        CryptoPassed parsedSignature
            | not (Ed25519.verify parsedKey (buildSignedMaterial binding) parsedSignature) ->
                pure (Left (BuildSignatureInvalid "the grant does not authenticate this binding"))
            | otherwise -> do
                consumed <- newIORef []
                Right
                    <$> use
                        (ImageBuildFrame (buildFrameName binding))
                        (BuildInvocationAuthority (buildIdentifier binding) actualSource consumed)
      where
        BuildVerificationKey parsedKey = key

-- ---------------------------------------------------------------------------
-- Narrow phase authority

{- | The only two things an authenticated build invocation may authorize.

Deliberately closed: a build authority is not a project verb, so no amount of it
adds up to @project up@.
-}
data BuildPhaseKind
    = CheckCodePhase
    | BuildPhase
    deriving (Eq, Show)

-- | Authority to run one build phase. Opaque; derived only from a verified pair.
data BuildCommandAuthority projectId specDigest configId
    = BuildCommandAuthority BuildPhaseKind BuildFrameName

type role BuildCommandAuthority nominal nominal nominal

instance Show (BuildCommandAuthority projectId specDigest configId) where
    show (BuildCommandAuthority phase frame) =
        "BuildCommandAuthority " <> show phase <> " " <> Text.unpack (buildFrameNameText frame)

buildCommandAuthorityPhase :: BuildCommandAuthority projectId specDigest configId -> BuildPhaseKind
buildCommandAuthorityPhase (BuildCommandAuthority phase _) = phase

-- | Derive check-code authority from a verified build invocation.
authorizeCheckCode ::
    ImageBuildFrame projectId specDigest configId frame ->
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest ->
    IO (Either BuildError (BuildCommandAuthority projectId specDigest configId))
authorizeCheckCode = authorizePhase CheckCodePhase

-- | Derive build-phase authority from a verified build invocation.
authorizeBuildPhase ::
    ImageBuildFrame projectId specDigest configId frame ->
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest ->
    IO (Either BuildError (BuildCommandAuthority projectId specDigest configId))
authorizeBuildPhase = authorizePhase BuildPhase

authorizePhase ::
    BuildPhaseKind ->
    ImageBuildFrame projectId specDigest configId frame ->
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest ->
    IO (Either BuildError (BuildCommandAuthority projectId specDigest configId))
authorizePhase phase (ImageBuildFrame frame) (BuildInvocationAuthority _ _ consumed) = do
    firstUse <-
        atomicModifyIORef' consumed $ \phases ->
            if phase `elem` phases
                then (phases, False)
                else (phase : phases, True)
    pure $
        if firstUse
            then Right (BuildCommandAuthority phase frame)
            else Left (BuildPhaseAlreadyAuthorized phase)

-- ---------------------------------------------------------------------------
-- Digests and failures

data BuildError
    = -- | what, the signed value, then the locally measured one
      BuildIdentityMismatch Text Text Text
    | BuildSignatureInvalid Text
    | BuildSigningKeyUnavailable Text
    | BuildSigningKeyInvalid Text
    | BuildVerificationKeyUnavailable Text
    | BuildVerificationKeyInvalid Text
    | BuildCoordinatorExpired
    | BuildSourceUnavailable Text
    | BuildBinaryUnavailable Text
    | -- | this build backend has no coordinator channel
      BuildChannelUnavailable Text
    | BuildChannelMalformed Text
    | BuildPhaseAlreadyAuthorized BuildPhaseKind
    deriving (Eq, Show)

buildErrorMessage :: BuildError -> String
buildErrorMessage err = case err of
    BuildIdentityMismatch what signed measured ->
        "build authority: "
            <> Text.unpack what
            <> " mismatch (grant says "
            <> Text.unpack signed
            <> ", measured "
            <> Text.unpack measured
            <> ")"
    BuildSignatureInvalid detail -> "build authority: " <> Text.unpack detail
    BuildSigningKeyUnavailable detail ->
        "build authority: the signing key is unavailable: " <> Text.unpack detail
    BuildSigningKeyInvalid detail ->
        "build authority: the signing key is invalid: " <> Text.unpack detail
    BuildVerificationKeyUnavailable detail ->
        "build authority: the installed verification key is unavailable: " <> Text.unpack detail
    BuildVerificationKeyInvalid detail ->
        "build authority: the installed verification key is invalid: " <> Text.unpack detail
    BuildCoordinatorExpired ->
        "build authority: the coordinator signing bracket has expired"
    BuildSourceUnavailable detail ->
        "build authority: cannot measure the source context: " <> Text.unpack detail
    BuildBinaryUnavailable detail ->
        "build authority: cannot measure the binary: " <> Text.unpack detail
    BuildChannelUnavailable detail ->
        "build authority: no coordinator channel: " <> Text.unpack detail
    BuildChannelMalformed detail -> "build authority: malformed channel: " <> Text.unpack detail
    BuildPhaseAlreadyAuthorized phase ->
        "build authority: " <> show phase <> " was already authorized for this invocation"

firstLine :: String -> String
firstLine = takeWhile (/= '\n')
