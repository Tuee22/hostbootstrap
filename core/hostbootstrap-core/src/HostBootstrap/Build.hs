{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Build-invocation authority for the in-Dockerfile quality gate (§ X,
the operator-root-and-command-authority phase).

Today the derived image runs @project init --role image-build-container@ and
then @check-code@, and the gate authorizes from that **baked** config alone. The
config is a file the Dockerfile just wrote, so it proves only that a Dockerfile
ran: nothing binds the gate to the project whose sources are being built, to the
exact source context, or to the binary doing the building. A stale or copied
image-build config authorizes the same gate.

This module supplies the ephemeral authority the gate should require instead.
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
import Control.Exception (SomeException, evaluate, finally, try)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import qualified Crypto.Hash as Hash
import qualified Crypto.PubKey.Ed25519 as Ed25519
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteArray (convert)
import qualified Data.ByteArray as ByteArray
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (sort)
import Data.Text (Text)
import Data.Word (Word64, Word8)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Handoff (
    frameWire,
    unframeWire,
 )
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))

-- ---------------------------------------------------------------------------
-- Bindings

{- | Everything a build grant authenticates.

The two binary digests are separate on purpose: the **coordinator** is the
process that decided to build, and the **builder** is the binary that will run
the gate inside the image. A grant issued for one builder cannot authorize a
different one even when everything else matches.
-}
data BuildBinding = BuildBinding
    { buildProjectName :: Text
    , buildSpecDigest :: Text
    , buildConfigDigest :: Text
    , buildIdentifier :: Text
    , buildSourceDigest :: Text
    , buildCoordinatorDigest :: Text
    , buildBuilderDigest :: Text
    , buildFrameName :: Text
    }
    deriving (Eq, Show)

-- | Canonical bytes, length-prefixed per field so no two bindings collide.
renderBuildBinding :: BuildBinding -> ByteString
renderBuildBinding binding =
    ByteString.concat
        [ field (buildProjectName binding)
        , field (buildSpecDigest binding)
        , field (buildConfigDigest binding)
        , field (buildIdentifier binding)
        , field (buildSourceDigest binding)
        , field (buildCoordinatorDigest binding)
        , field (buildBuilderDigest binding)
        , field (buildFrameName binding)
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
            loaded <- try (ByteString.readFile path) :: IO (Either SomeException ByteString)
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
    , coordinatorDigest :: Text
    , coordinatorActive :: MVar Bool
    }

type role BuildCoordinator nominal

instance Show (BuildCoordinator coordinatorId) where
    show coordinator = "BuildCoordinator <signing> " <> Text.unpack (coordinatorDigest coordinator)

{- | Run an action with one active use of the provisioned signing key, bound to
the coordinator binary's measured digest.
-}
withBuildCoordinator ::
    BuildSigningKey ->
    -- | the coordinator binary's measured digest
    Text ->
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
                                    (buildCoordinatorDigest binding)
                                    (coordinatorDigest coordinator)
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

{- | Digest a source context deterministically.

Path and contents are both length-prefixed and the entries are sorted, so two
different trees cannot measure the same — in particular, moving a file's bytes
to a differently named file changes the digest. Paths are encoded as UTF-8,
without the lossy low-byte projection of @Char8@. A missing root is a typed
refusal rather than an empty-tree digest, which would otherwise let an image
built from no sources satisfy a grant.
-}
measureSourceDigest :: FilePath -> IO (Either BuildError Text)
measureSourceDigest root = do
    present <- doesDirectoryExist root
    if not present
        then pure (Left (BuildSourceUnavailable (Text.pack root)))
        else do
            collected <- try (collect "" root) :: IO (Either SomeException [(FilePath, ByteString)])
            pure $ case collected of
                Left err ->
                    Left (BuildSourceUnavailable (Text.pack (root <> ": " <> firstLine (show err))))
                Right entries ->
                    Right
                        ( sha256Hex
                            ( ByteString.concat
                                [ frameWire (TextEncoding.encodeUtf8 (Text.pack path)) <> frameWire contents
                                | (path, contents) <- sort entries
                                ]
                            )
                        )
  where
    collect prefix directory = do
        names <- listDirectory directory
        fmap concat (traverse (visit prefix directory) (sort names))

    visit prefix directory name = do
        let absolute = directory </> name
            relative = if null prefix then name else prefix <> "/" <> name
        isDirectory <- doesDirectoryExist absolute
        if isDirectory
            then collect relative absolute
            else do
                isFile <- doesFileExist absolute
                if isFile
                    then do
                        contents <- ByteString.readFile absolute
                        pure [(relative, contents)]
                    else pure []

{- | Digest a binary on disk. Used for both the coordinator and builder
identities; a missing path is a typed refusal, never a skipped comparison.
-}
measureBinaryDigest :: FilePath -> IO (Either BuildError Text)
measureBinaryDigest path = do
    present <- doesFileExist path
    if not present
        then pure (Left (BuildBinaryUnavailable (Text.pack path)))
        else do
            loaded <- try (ByteString.readFile path) :: IO (Either SomeException ByteString)
            pure $ case loaded of
                Left err ->
                    Left (BuildBinaryUnavailable (Text.pack (path <> ": " <> firstLine (show err))))
                Right contents -> Right (sha256Hex contents)

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
            loaded <- try (ByteString.readFile path) :: IO (Either SomeException ByteString)
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
                                    { buildProjectName = p
                                    , buildSpecDigest = sp
                                    , buildConfigDigest = c
                                    , buildIdentifier = b
                                    , buildSourceDigest = so
                                    , buildCoordinatorDigest = co
                                    , buildBuilderDigest = bu
                                    , buildFrameName = f
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
    go remaining rest acc
        | ByteString.length rest < 8 = Left (BuildChannelMalformed "truncated channel")
        | ByteString.length body < declared = Left (BuildChannelMalformed "truncated channel field")
        | otherwise =
            go (remaining - 1) (ByteString.drop declared body) (ByteString.take declared body : acc)
      where
        declared = fromIntegral (bigEndianWord (ByteString.unpack (ByteString.take 8 rest)))
        body = ByteString.drop 8 rest

bigEndianWord :: [Word8] -> Word64
bigEndianWord = foldl (\acc byte -> (acc `shiftL` 8) .|. fromIntegral byte) 0

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
data ImageBuildFrame projectId specDigest configId frame = ImageBuildFrame Text

type role ImageBuildFrame nominal nominal nominal nominal

instance Show (ImageBuildFrame projectId specDigest configId frame) where
    show (ImageBuildFrame name) = "ImageBuildFrame " <> Text.unpack name

imageBuildFrameName :: ImageBuildFrame projectId specDigest configId frame -> Text
imageBuildFrameName (ImageBuildFrame name) = name

{- | Ephemeral authority for one successful verification result. Opaque: it
exists only as a result of 'verifyBuildInvocation'. Each result owns its own
in-memory phase-consumption state; cross-presentation replay belongs to the
concrete command/channel consumer.
-}
data BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest
    = BuildInvocationAuthority Text Text (IORef [BuildPhaseKind])

type role BuildInvocationAuthority nominal nominal nominal nominal nominal nominal

instance Show (BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest) where
    show (BuildInvocationAuthority buildId _ _) = "BuildInvocationAuthority " <> Text.unpack buildId

buildAuthorityBuildId ::
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest -> Text
buildAuthorityBuildId (BuildInvocationAuthority value _ _) = value

buildAuthoritySourceDigest ::
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest -> Text
buildAuthoritySourceDigest (BuildInvocationAuthority _ value _) = value

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
    Text ->
    -- | the finalized Production codec's locally computed spec digest
    Text ->
    -- | the locally computed Production config digest
    Text ->
    -- | the installed coordinator binary identity
    Text ->
    -- | the caller-selected source root to measure
    FilePath ->
    -- | the caller-selected builder path to measure
    FilePath ->
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
        pure (Left (BuildIdentityMismatch "project" (buildProjectName binding) projectName))
    | buildSpecDigest binding /= specDigest =
        pure (Left (BuildIdentityMismatch "spec digest" (buildSpecDigest binding) specDigest))
    | buildConfigDigest binding /= configDigest =
        pure (Left (BuildIdentityMismatch "config digest" (buildConfigDigest binding) configDigest))
    | buildCoordinatorDigest binding /= expectedCoordinator =
        pure
            ( Left
                ( BuildIdentityMismatch
                    "coordinator binary"
                    (buildCoordinatorDigest binding)
                    expectedCoordinator
                )
            )
    | Text.null (buildIdentifier binding) =
        pure (Left (BuildChannelMalformed "the build id is empty"))
    | Text.null (buildFrameName binding) =
        pure (Left (BuildChannelMalformed "the image-build frame is empty"))
    | otherwise = do
        measuredSource <- measureSourceDigest sourceRoot
        case measuredSource of
            Left failure -> pure (Left failure)
            Right actualSource
                | buildSourceDigest binding /= actualSource ->
                    pure
                        ( Left
                            (BuildIdentityMismatch "source digest" (buildSourceDigest binding) actualSource)
                        )
                | otherwise -> do
                    measuredBuilder <- measureBinaryDigest builderPath
                    case measuredBuilder of
                        Left failure -> pure (Left failure)
                        Right actualBuilder
                            | buildBuilderDigest binding /= actualBuilder ->
                                pure
                                    ( Left
                                        ( BuildIdentityMismatch
                                            "builder binary"
                                            (buildBuilderDigest binding)
                                            actualBuilder
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
    = BuildCommandAuthority BuildPhaseKind Text

type role BuildCommandAuthority nominal nominal nominal

instance Show (BuildCommandAuthority projectId specDigest configId) where
    show (BuildCommandAuthority phase frame) =
        "BuildCommandAuthority " <> show phase <> " " <> Text.unpack frame

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

sha256Hex :: ByteString -> Text
sha256Hex payload =
    Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 payload)))
  where
    hex byte = [hexDigit (byte `shiftR` 4), hexDigit (byte .&. 0x0f)]
    hexDigit nibble = ByteStringChar8.index "0123456789abcdef" (fromIntegral nibble)

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
