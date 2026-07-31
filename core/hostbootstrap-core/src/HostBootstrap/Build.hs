{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Build-invocation authority for the in-Dockerfile quality gate (§ X,
Sprint 15.9).

Today the derived image runs @project init --role image-build-container@ and
then @check-code@, and the gate authorizes from that **baked** config alone. The
config is a file the Dockerfile just wrote, so it proves only that a Dockerfile
ran: nothing binds the gate to the project whose sources are being built, to the
exact source context, or to the binary doing the building. A stale or copied
image-build config authorizes the same gate.

This module supplies the ephemeral authority the gate should require instead.
The build coordinator — the process that decided to build this image — signs a
'BuildBinding' naming the project, spec digest, config digest, build id, source
digest, and both binary identities. Inside the image, verification:

* takes its verification key from an **installed** file, never from the grant;
* **independently measures** the source context and compares it with the signed
  digest, so a grant cannot describe sources other than the ones present;
* **independently measures** the running builder binary and compares it, so a
  grant minted for one builder cannot authorize another;
* requires the locally computed Production config digest to match the signed
  one.

Only then does it jointly yield 'ImageBuildFrame' and
'BuildInvocationAuthority', from which the two narrow phase authorities
('CheckCodePhase', 'BuildPhase') are derived. There is no function here that
takes a @BinaryContext@: the baked config cannot reach any of it.

@ImageBuildScope@ is a build *command* scope, not a third secret scope — nothing
in this module carries secrets, and the image digest is recorded only after the
pre-image, source-bound gate has already succeeded.
-}
module HostBootstrap.Build (
    -- * The signed binding
    BuildBinding (..),
    renderBuildBinding,

    -- * The coordinator side
    BuildCoordinator,
    withBuildCoordinator,
    buildCoordinatorKey,
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

import Control.Exception (SomeException, try)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import qualified Crypto.Hash as Hash
import qualified Crypto.PubKey.Ed25519 as Ed25519
import Crypto.Random (getRandomBytes)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteArray (convert)
import qualified Data.ByteArray as ByteArray
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.List (sort)
import Data.Text (Text)
import Data.Word (Word64, Word8)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Handoff (
    ProjectVerificationKey,
    frameWire,
    unframeWire,
    verificationKeyBytes,
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
-- Coordinator

{- | The build coordinator's signing capability. Minted only inside
'withBuildCoordinator' and never returned from it, so it cannot be captured into
a value the image receives.
-}
data BuildCoordinator = BuildCoordinator
    { coordinatorSecret :: Ed25519.SecretKey
    , coordinatorPublic :: Ed25519.PublicKey
    , coordinatorDigest :: Text
    }

instance Show BuildCoordinator where
    show coordinator = "BuildCoordinator <signing> " <> Text.unpack (coordinatorDigest coordinator)

-- | The public half the image must have installed to verify this coordinator.
buildCoordinatorKey :: BuildCoordinator -> ByteString
buildCoordinatorKey = convert . coordinatorPublic

{- | Run an action with a fresh coordinator keypair bound to the coordinator
binary's measured digest.
-}
withBuildCoordinator ::
    -- | the coordinator binary's measured digest
    Text ->
    (BuildCoordinator -> IO result) ->
    IO result
withBuildCoordinator digest use = do
    seed <- getRandomBytes 32 :: IO ByteString
    secret <- case Ed25519.secretKey seed of
        CryptoFailed err -> ioError (userError ("build coordinator key generation failed: " <> show err))
        CryptoPassed value -> pure value
    use
        BuildCoordinator
            { coordinatorSecret = secret
            , coordinatorPublic = Ed25519.toPublic secret
            , coordinatorDigest = digest
            }

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
signBuildGrant :: BuildCoordinator -> BuildBinding -> Either BuildError BuildGrant
signBuildGrant coordinator binding
    | buildCoordinatorDigest binding /= coordinatorDigest coordinator =
        Left
            ( BuildIdentityMismatch
                "coordinator"
                (buildCoordinatorDigest binding)
                (coordinatorDigest coordinator)
            )
    | otherwise =
        Right
            ( BuildGrant
                ( convert
                    ( Ed25519.sign
                        (coordinatorSecret coordinator)
                        (coordinatorPublic coordinator)
                        (renderBuildBinding binding)
                    )
                )
            )

-- ---------------------------------------------------------------------------
-- Measurement

{- | Digest a source context deterministically.

Path and contents are both length-prefixed and the entries are sorted, so two
different trees cannot measure the same — in particular, moving a file's bytes
to a differently named file changes the digest. A missing root is a typed
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
                                [ frameWire (ByteStringChar8.pack path) <> frameWire contents
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

instance Show (ImageBuildFrame projectId specDigest configId frame) where
    show (ImageBuildFrame name) = "ImageBuildFrame " <> Text.unpack name

imageBuildFrameName :: ImageBuildFrame projectId specDigest configId frame -> Text
imageBuildFrameName (ImageBuildFrame name) = name

{- | Ephemeral authority for one authenticated build invocation. Opaque: it
exists only as a result of 'verifyBuildInvocation'.
-}
data BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest
    = BuildInvocationAuthority Text Text

instance Show (BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest) where
    show (BuildInvocationAuthority buildId _) = "BuildInvocationAuthority " <> Text.unpack buildId

buildAuthorityBuildId ::
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest -> Text
buildAuthorityBuildId (BuildInvocationAuthority value _) = value

buildAuthoritySourceDigest ::
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest -> Text
buildAuthoritySourceDigest (BuildInvocationAuthority _ value) = value

{- | Verify a delivered build channel inside the image.

Every comparison is against something measured or computed locally, never
against a value the grant supplies about itself. The verification key is an
installed input; the source digest is measured from the context actually
present; the builder digest is measured from the binary actually running; and
the config digest is the one the caller computed through the Production project
codec.
-}
verifyBuildInvocation ::
    -- | the installed verification key
    ProjectVerificationKey ->
    -- | the locally verified project name
    Text ->
    -- | the locally computed Production config digest
    Text ->
    -- | the source context root to measure
    FilePath ->
    -- | the running builder binary to measure
    FilePath ->
    BuildChannel ->
    IO
        ( Either
            BuildError
            ( ImageBuildFrame projectId specDigest configId frame
            , BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest
            )
        )
verifyBuildInvocation key projectName configDigest sourceRoot builderPath channel
    | buildProjectName binding /= projectName =
        pure (Left (BuildIdentityMismatch "project" (buildProjectName binding) projectName))
    | buildConfigDigest binding /= configDigest =
        pure (Left (BuildIdentityMismatch "config digest" (buildConfigDigest binding) configDigest))
    | Text.null (buildIdentifier binding) =
        pure (Left (BuildChannelMalformed "the build id is empty"))
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
                            | otherwise -> pure (checkSignature actualSource)
  where
    binding = channelBinding channel
    BuildGrant signature = channelGrant channel

    checkSignature actualSource = case Ed25519.publicKey (verificationKeyBytes key) of
        CryptoFailed err -> Left (BuildVerificationKeyUnusable (Text.pack (show err)))
        CryptoPassed parsedKey -> case Ed25519.signature signature of
            CryptoFailed err -> Left (BuildSignatureInvalid (Text.pack (show err)))
            CryptoPassed parsedSignature
                | not (Ed25519.verify parsedKey (renderBuildBinding binding) parsedSignature) ->
                    Left (BuildSignatureInvalid "the grant does not authenticate this binding")
                | otherwise ->
                    Right
                        ( ImageBuildFrame (buildFrameName binding)
                        , BuildInvocationAuthority (buildIdentifier binding) actualSource
                        )

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

instance Show (BuildCommandAuthority projectId specDigest configId) where
    show (BuildCommandAuthority phase frame) =
        "BuildCommandAuthority " <> show phase <> " " <> Text.unpack frame

buildCommandAuthorityPhase :: BuildCommandAuthority projectId specDigest configId -> BuildPhaseKind
buildCommandAuthorityPhase (BuildCommandAuthority phase _) = phase

-- | Derive check-code authority from a verified build invocation.
authorizeCheckCode ::
    ImageBuildFrame projectId specDigest configId frame ->
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest ->
    BuildCommandAuthority projectId specDigest configId
authorizeCheckCode (ImageBuildFrame frame) _ = BuildCommandAuthority CheckCodePhase frame

-- | Derive build-phase authority from a verified build invocation.
authorizeBuildPhase ::
    ImageBuildFrame projectId specDigest configId frame ->
    BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest ->
    BuildCommandAuthority projectId specDigest configId
authorizeBuildPhase (ImageBuildFrame frame) _ = BuildCommandAuthority BuildPhase frame

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
    | BuildVerificationKeyUnusable Text
    | BuildSourceUnavailable Text
    | BuildBinaryUnavailable Text
    | -- | this build backend has no coordinator channel
      BuildChannelUnavailable Text
    | BuildChannelMalformed Text
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
    BuildVerificationKeyUnusable detail ->
        "build authority: the installed verification key is unusable: " <> Text.unpack detail
    BuildSourceUnavailable detail ->
        "build authority: cannot measure the source context: " <> Text.unpack detail
    BuildBinaryUnavailable detail ->
        "build authority: cannot measure the binary: " <> Text.unpack detail
    BuildChannelUnavailable detail ->
        "build authority: no coordinator channel: " <> Text.unpack detail
    BuildChannelMalformed detail -> "build authority: malformed channel: " <> Text.unpack detail

firstLine :: String -> String
firstLine = takeWhile (/= '\n')
