{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The authenticated cross-frame handoff transport (§ X, § EE, Sprint 15.9).

A parent frame that descends into a VM, container, or pod must give the child
its narrowed config. The mechanism this replaces was a shell writer: the parent
put the rendered payload on the lift's @stdin@ and overrode the container
entrypoint with @sh -c "cat > \<sibling\> && exec \<binary\> …"@. That delivers
bytes, but it authenticates nothing — whatever arrives on @stdin@ becomes the
child's config, and the child cannot tell a parent-rendered projection from
anything else that reached the same pipe.

The transport here is the authenticated peer:

* every handoff is bound to one exact 'HandoffBinding' — scope, plan revision,
  broker generation, the parent→child frame edge, the child config digest, and
  the verb\/phase. Bindings are rendered with length-prefixed fields, so two
  different bindings cannot render to the same bytes;
* the **root** invocation owns the signing key ('RootBroker'). Immediate parents
  get only a keyless 'BrokerRelay': they can carry an offer and relay a grant
  request, and they cannot sign, delegate, or mint one themselves;
* the child's receiver mints a **fresh** 'HandoffChallenge' and the root signs
  over it, so a recorded transcript cannot be replayed into a later handoff;
* the offer's one-time token is consumed by a protected compare-and-swap, so a
  second use of the same token is refused even if the challenge is satisfied;
* verification recomputes the config digest from the bytes **actually
  received**, and takes the verification key as a separate installed input. A
  key carried in the envelope is never consulted.

Nothing here reads or writes @argv@ or the environment, and no value in this
module is representable in Dhall.
-}
module HostBootstrap.Handoff (
    -- * Length-delimited framing
    frameWire,
    unframeWire,
    maxWireBytes,

    -- * The exact binding a handoff authenticates
    HandoffBinding (..),
    renderHandoffBinding,
    childConfigDigest,

    -- * Installed verification key
    ProjectVerificationKey,
    installedVerificationKey,
    verificationKeyBytes,

    -- * The root broker and its keyless relay
    RootBroker,
    withRootBroker,
    rootBrokerVerificationKey,
    BrokerRelay,
    brokerRelay,
    relayBinding,

    -- * Offer, challenge, grant
    HandoffOffer,
    mkHandoffOffer,
    handoffOfferWire,
    handoffOfferBinding,
    HandoffChallenge,
    freshChallenge,
    challengeBytes,
    HandoffGrant,
    grantSignature,
    signHandoffGrant,

    -- * Verified results
    VerifiedHandoff,
    verifiedHandoffBinding,
    verifiedHandoffPayload,
    verifyHandoff,
    ChildPlanAuthority,
    childPlanAuthorityBinding,
    authorizeChildProject,

    -- * Failures
    HandoffError (..),
    handoffErrorMessage,
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
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64, Word8)
import HostBootstrap.Authority (
    ProjectVerb,
    RootInvocationAuthority,
    brokerEpochWord,
    projectVerbName,
    rootAuthorityEpoch,
    rootAuthorityVerb,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    ProtectedError,
    ProtectedSession,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    protectedErrorMessage,
 )
import System.Directory (doesFileExist)

-- ---------------------------------------------------------------------------
-- Framing

{- | The largest wire a receiver will accept. A declared length beyond this is
refused before any allocation, so a hostile length prefix cannot ask the
receiver to reserve an arbitrary buffer.
-}
maxWireBytes :: Word64
maxWireBytes = 8 * 1024 * 1024

{- | Length-delimit a payload: an 8-byte big-endian length followed by exactly
that many bytes. Framing is what lets the receiver know a message ended rather
than inferring it from a closed pipe.
-}
frameWire :: ByteString -> ByteString
frameWire payload =
    ByteString.pack (word64BigEndian (fromIntegral (ByteString.length payload)))
        <> payload

{- | Read exactly one framed payload, and require the frame to be the whole
input. Truncation, a short header, trailing bytes after the declared length, and
an oversized declared length are each a distinct refusal rather than a partial
read.
-}
unframeWire :: ByteString -> Either HandoffError ByteString
unframeWire raw
    | ByteString.length raw < 8 =
        Left (HandoffWireTruncated 8 (ByteString.length raw))
    | declared > maxWireBytes =
        Left (HandoffWireTooLarge declared maxWireBytes)
    | fromIntegral (ByteString.length body) < declared =
        Left (HandoffWireTruncated (fromIntegral declared) (ByteString.length body))
    | not (ByteString.null trailing) =
        Left (HandoffWireTrailingBytes (ByteString.length trailing))
    | otherwise = Right payload
  where
    (header, body) = ByteString.splitAt 8 raw
    declared = bigEndianWord64 (ByteString.unpack header)
    (payload, trailing) = ByteString.splitAt (fromIntegral declared) body

word64BigEndian :: Word64 -> [Word8]
word64BigEndian value =
    [fromIntegral ((value `shiftR` shift) .&. 0xff) | shift <- [56, 48, 40, 32, 24, 16, 8, 0]]

bigEndianWord64 :: [Word8] -> Word64
bigEndianWord64 = foldl (\acc byte -> (acc `shiftL` 8) .|. fromIntegral byte) 0

-- ---------------------------------------------------------------------------
-- Bindings

{- | The exact tuple a handoff token and grant are bound to.

Everything that distinguishes one legitimate handoff from another lives here, so
a grant for one edge cannot authorize a different one. In particular the
@parent -> child@ frame pair is part of the signed material: a sibling frame
cannot present a grant minted for its peer.
-}
data HandoffBinding = HandoffBinding
    { handoffScope :: Text
    -- ^ the descriptive scope tag (@Production@ or @Harness \<runId\>@)
    , handoffPlanRevision :: Text
    , handoffBrokerGeneration :: Word64
    , handoffParentFrame :: Text
    , handoffChildFrame :: Text
    , handoffChildConfigDigest :: Text
    , handoffVerb :: Text
    , handoffPhase :: Text
    }
    deriving (Eq, Show)

{- | Canonical bytes for a binding.

Each field is length-prefixed rather than separator-joined. With a separator, a
parent frame named @"a-b"@ and child @"c"@ would render identically to parent
@"a"@ and child @"b-c"@, and one grant would authenticate two different edges.
Length prefixes make the field boundaries unambiguous.
-}
renderHandoffBinding :: HandoffBinding -> ByteString
renderHandoffBinding binding =
    ByteString.concat
        [ field (handoffScope binding)
        , field (handoffPlanRevision binding)
        , frameWire (ByteString.pack (word64BigEndian (handoffBrokerGeneration binding)))
        , field (handoffParentFrame binding)
        , field (handoffChildFrame binding)
        , field (handoffChildConfigDigest binding)
        , field (handoffVerb binding)
        , field (handoffPhase binding)
        ]
  where
    field = frameWire . TextEncoding.encodeUtf8

-- ---------------------------------------------------------------------------
-- Keys

{- | The project's public verification key, installed alongside the binary and
independent of any config.

It is deliberately *not* reachable from a 'HandoffOffer': a receiver that took
its verification key from the envelope would verify every well-formed forgery.
-}
newtype ProjectVerificationKey = ProjectVerificationKey Ed25519.PublicKey
    deriving (Eq)

instance Show ProjectVerificationKey where
    show _ = "ProjectVerificationKey <installed>"

-- | The raw public key bytes, for writing an installed key file.
verificationKeyBytes :: ProjectVerificationKey -> ByteString
verificationKeyBytes (ProjectVerificationKey key) = convert key

{- | Load the installed verification key from an absolute path. A missing,
unreadable, or wrong-length key file is a typed refusal — never a silently
skipped verification.
-}
installedVerificationKey :: FilePath -> IO (Either HandoffError ProjectVerificationKey)
installedVerificationKey path = do
    present <- doesFileExist path
    if not present
        then pure (Left (HandoffVerificationKeyUnavailable ("no installed key at " <> Text.pack path)))
        else do
            loaded <- try (ByteString.readFile path) :: IO (Either SomeException ByteString)
            pure $ case loaded of
                Left err ->
                    Left
                        ( HandoffVerificationKeyUnavailable
                            ("failed to read " <> Text.pack path <> ": " <> firstLine (show err))
                        )
                Right raw -> case Ed25519.publicKey raw of
                    CryptoFailed err ->
                        Left
                            ( HandoffVerificationKeyUnavailable
                                ("malformed key at " <> Text.pack path <> ": " <> Text.pack (show err))
                            )
                    CryptoPassed key -> Right (ProjectVerificationKey key)

{- | The root invocation's signing capability.

Minted only inside 'withRootBroker' from a verified 'RootInvocationAuthority',
and never returned from it, so the key cannot outlive the invocation that earned
it or be stored in a value a child receives.
-}
data RootBroker scope brokerGeneration verb = RootBroker
    { brokerSecret :: Ed25519.SecretKey
    , brokerPublic :: Ed25519.PublicKey
    , brokerEpochValue :: Word64
    , brokerVerbName :: Text
    }

instance Show (RootBroker scope brokerGeneration verb) where
    show broker = "RootBroker <signing> " <> show (brokerEpochValue broker)

-- | The public half a child binary must have installed to verify this broker.
rootBrokerVerificationKey :: RootBroker scope brokerGeneration verb -> ProjectVerificationKey
rootBrokerVerificationKey = ProjectVerificationKey . brokerPublic

{- | Run an action with a freshly generated root broker keypair, bound to the
verified root invocation's epoch and verb.

The keypair lives only for the duration of the continuation. A new invocation
gets a new key, so a grant captured from an earlier run cannot verify against
the key a later run installs.
-}
withRootBroker ::
    RootInvocationAuthority scope brokerGeneration verb ->
    (RootBroker scope brokerGeneration verb -> IO result) ->
    IO result
withRootBroker root use = do
    seed <- getRandomBytes 32 :: IO ByteString
    secret <- case Ed25519.secretKey seed of
        CryptoFailed err -> ioError (userError ("broker key generation failed: " <> show err))
        CryptoPassed value -> pure value
    use
        RootBroker
            { brokerSecret = secret
            , brokerPublic = Ed25519.toPublic secret
            , brokerEpochValue = brokerEpochWord (rootAuthorityEpoch root)
            , brokerVerbName = projectVerbName (rootAuthorityVerb root)
            }

{- | What an immediate parent is given: the binding it may carry, and nothing
else.

There is deliberately no field here from which a signature can be produced. A
parent relays; the root signs.
-}
newtype BrokerRelay scope brokerGeneration = BrokerRelay HandoffBinding
    deriving (Eq, Show)

-- | Hand a parent the relay for one edge.
brokerRelay ::
    RootBroker scope brokerGeneration verb ->
    HandoffBinding ->
    Either HandoffError (BrokerRelay scope brokerGeneration)
brokerRelay broker binding
    | handoffBrokerGeneration binding /= brokerEpochValue broker =
        Left
            ( HandoffBindingMismatch
                "the binding names a different broker generation than the live root broker"
            )
    | handoffVerb binding /= brokerVerbName broker =
        Left
            ( HandoffBindingMismatch
                "the binding names a different verb than the root invocation authorized"
            )
    | otherwise = Right (BrokerRelay binding)

-- | The binding a relay carries. Descriptive; it authorizes nothing on its own.
relayBinding :: BrokerRelay scope brokerGeneration -> HandoffBinding
relayBinding (BrokerRelay binding) = binding

-- ---------------------------------------------------------------------------
-- Offer, challenge, grant

{- | What crosses the boundary: the length-delimited narrowed config wire plus
the one-time token identifying this handoff.

The payload is carried as bytes and the token is a separate framed field, so the
receiver never has to parse config to find where the token starts.
-}
data HandoffOffer = HandoffOffer
    { offerBinding :: HandoffBinding
    , offerPayload :: ByteString
    , offerToken :: Text
    }
    deriving (Eq, Show)

{- | Build an offer from a relay and the exact child config bytes.

The binding's declared child-config digest must match the bytes being sent. This
is checked here so a parent cannot construct an offer whose digest describes a
different payload than the one it is about to transmit.
-}
mkHandoffOffer ::
    BrokerRelay scope brokerGeneration ->
    -- | the exact narrowed child config bytes
    ByteString ->
    -- | the one-time token identifying this handoff
    Text ->
    Either HandoffError HandoffOffer
mkHandoffOffer (BrokerRelay binding) payload token
    | Text.null token = Left (HandoffTokenInvalid "a handoff token must not be empty")
    | handoffChildConfigDigest binding /= childConfigDigest payload =
        Left
            ( HandoffBindingMismatch
                "the binding's child config digest does not describe the payload being offered"
            )
    | otherwise =
        Right
            HandoffOffer
                { offerBinding = binding
                , offerPayload = payload
                , offerToken = token
                }

-- | The framed bytes an offer transmits: the config wire then the token.
handoffOfferWire :: HandoffOffer -> ByteString
handoffOfferWire offer =
    frameWire (offerPayload offer)
        <> frameWire (TextEncoding.encodeUtf8 (offerToken offer))

-- | The binding an offer claims. Descriptive until a grant authenticates it.
handoffOfferBinding :: HandoffOffer -> HandoffBinding
handoffOfferBinding = offerBinding

{- | A receiver-generated nonce.

Freshness is the whole point: because the root signs over the challenge, a
transcript recorded from an earlier handoff carries a signature over a challenge
this receiver did not issue, and fails verification.
-}
newtype HandoffChallenge = HandoffChallenge ByteString
    deriving (Eq)

instance Show HandoffChallenge where
    show _ = "HandoffChallenge <fresh>"

-- | The raw challenge bytes, for transmission back to the root.
challengeBytes :: HandoffChallenge -> ByteString
challengeBytes (HandoffChallenge value) = value

-- | Mint a fresh challenge in the receiving binary.
freshChallenge :: IO HandoffChallenge
freshChallenge = HandoffChallenge <$> (getRandomBytes 32 :: IO ByteString)

{- | The root's signature over one challenge and one binding. Opaque: a
consumer cannot alter which binding a grant speaks for.
-}
newtype HandoffGrant = HandoffGrant ByteString
    deriving (Eq)

instance Show HandoffGrant where
    show _ = "HandoffGrant <signed>"

-- | The raw signature bytes, for transmission.
grantSignature :: HandoffGrant -> ByteString
grantSignature (HandoffGrant value) = value

{- | Sign a grant. Only the root broker can do this, and only for a binding that
matches its own live generation and verb.
-}
signHandoffGrant ::
    RootBroker scope brokerGeneration verb ->
    HandoffBinding ->
    HandoffChallenge ->
    Either HandoffError HandoffGrant
signHandoffGrant broker binding challenge
    | handoffBrokerGeneration binding /= brokerEpochValue broker =
        Left
            ( HandoffBindingMismatch
                "refusing to sign a binding from a different broker generation"
            )
    | handoffVerb binding /= brokerVerbName broker =
        Left
            ( HandoffBindingMismatch
                "refusing to sign a binding for a verb this root did not authorize"
            )
    | otherwise =
        Right
            ( HandoffGrant
                ( convert
                    ( Ed25519.sign
                        (brokerSecret broker)
                        (brokerPublic broker)
                        (signedMaterial binding challenge)
                    )
                )
            )

{- | Exactly what a signature covers: the challenge and the canonical binding,
both length-prefixed so the boundary between them is unambiguous.
-}
signedMaterial :: HandoffBinding -> HandoffChallenge -> ByteString
signedMaterial binding (HandoffChallenge challenge) =
    frameWire challenge <> frameWire (renderHandoffBinding binding)

-- ---------------------------------------------------------------------------
-- Verification

{- | An authenticated handoff. Minted only by 'verifyHandoff'; the constructor
is private, so raw wire cannot be promoted into one.
-}
data VerifiedHandoff scope brokerGeneration = VerifiedHandoff
    { verifiedBinding :: HandoffBinding
    , verifiedPayload :: ByteString
    }

instance Show (VerifiedHandoff scope brokerGeneration) where
    show handoff = "VerifiedHandoff " <> show (verifiedBinding handoff)

-- | The authenticated binding.
verifiedHandoffBinding :: VerifiedHandoff scope brokerGeneration -> HandoffBinding
verifiedHandoffBinding = verifiedBinding

-- | The exact bytes whose digest the signature covered.
verifiedHandoffPayload :: VerifiedHandoff scope brokerGeneration -> ByteString
verifiedHandoffPayload = verifiedPayload

{- | Verify one received handoff and consume its one-time token.

The order matters. Signature verification happens first, so an unauthenticated
message cannot burn a token; token consumption happens before the verified value
is produced, so a replay of a fully valid message is refused even though its
signature is genuine.

The digest is recomputed from the bytes actually received rather than trusted
from the binding, and the verification key is the installed one supplied by the
caller — never a key carried in the message.
-}
verifyHandoff ::
    ProtectedSession session ->
    ProjectVerificationKey ->
    -- | the exact framed bytes received
    ByteString ->
    -- | the binding the receiver expects for its own edge
    HandoffBinding ->
    HandoffChallenge ->
    HandoffGrant ->
    IO (Either HandoffError (VerifiedHandoff scope brokerGeneration))
verifyHandoff session (ProjectVerificationKey key) received expected challenge (HandoffGrant signature) =
    case decodeOfferWire received of
        Left err -> pure (Left err)
        Right (payload, token)
            | childConfigDigest payload /= handoffChildConfigDigest expected ->
                pure
                    ( Left
                        ( HandoffPayloadDigestMismatch
                            (handoffChildConfigDigest expected)
                            (childConfigDigest payload)
                        )
                    )
            | otherwise -> case Ed25519.signature signature of
                CryptoFailed err ->
                    pure (Left (HandoffSignatureInvalid (Text.pack (show err))))
                CryptoPassed parsed
                    | not (Ed25519.verify key (signedMaterial expected challenge) parsed) ->
                        pure
                            ( Left
                                ( HandoffSignatureInvalid
                                    "the grant does not authenticate this challenge and binding"
                                )
                            )
                    | otherwise -> consumeToken session token payload expected

{- | Split the received wire into its two framed fields. A message with a
missing second frame, or trailing bytes after it, is refused.
-}
decodeOfferWire :: ByteString -> Either HandoffError (ByteString, Text)
decodeOfferWire raw = do
    (payload, afterPayload) <- takeFrame raw
    (tokenBytes, afterToken) <- takeFrame afterPayload
    if not (ByteString.null afterToken)
        then Left (HandoffWireTrailingBytes (ByteString.length afterToken))
        else case TextEncoding.decodeUtf8' tokenBytes of
            Left _ -> Left (HandoffTokenInvalid "the handoff token is not valid UTF-8")
            Right token
                | Text.null token -> Left (HandoffTokenInvalid "the handoff token is empty")
                | otherwise -> Right (payload, token)

takeFrame :: ByteString -> Either HandoffError (ByteString, ByteString)
takeFrame raw
    | ByteString.length raw < 8 = Left (HandoffWireTruncated 8 (ByteString.length raw))
    | declared > maxWireBytes = Left (HandoffWireTooLarge declared maxWireBytes)
    | fromIntegral (ByteString.length body) < declared =
        Left (HandoffWireTruncated (fromIntegral declared) (ByteString.length body))
    | otherwise = Right (ByteString.splitAt (fromIntegral declared) body)
  where
    (header, body) = ByteString.splitAt 8 raw
    declared = bigEndianWord64 (ByteString.unpack header)

{- | Burn the token with a compare-and-swap against its absence. The first
consumer publishes the record; every later one observes it present and is
refused.
-}
consumeToken ::
    ProtectedSession session ->
    Text ->
    ByteString ->
    HandoffBinding ->
    IO (Either HandoffError (VerifiedHandoff scope brokerGeneration))
consumeToken session token payload binding =
    case mkRecordKey (tokenRecordKey token) of
        Left failure -> pure (Left (HandoffStoreFailure failure))
        Right key -> do
            written <-
                compareAndSwapProtectedRecord
                    session
                    key
                    ExpectAbsent
                    (renderHandoffBinding binding)
            pure $ case written of
                Left _ -> Left (HandoffTokenConsumed token)
                Right _ ->
                    Right
                        VerifiedHandoff
                            { verifiedBinding = binding
                            , verifiedPayload = payload
                            }

tokenRecordKey :: Text -> Text
tokenRecordKey token = "handoff-token." <> childConfigDigest (TextEncoding.encodeUtf8 token)

-- ---------------------------------------------------------------------------
-- Child authority

{- | What a verified handoff earns the child: permission to act at its own
frame, for the exact verb and phase the root bound.

It deliberately carries no signing key and no root authority. A child that needs
a grandchild grant must ask the root relay for one; it cannot mint it.
-}
newtype ChildPlanAuthority scope brokerGeneration = ChildPlanAuthority HandoffBinding

instance Show (ChildPlanAuthority scope brokerGeneration) where
    show (ChildPlanAuthority binding) = "ChildPlanAuthority " <> show binding

-- | The authenticated binding this authority acts under.
childPlanAuthorityBinding :: ChildPlanAuthority scope brokerGeneration -> HandoffBinding
childPlanAuthorityBinding (ChildPlanAuthority binding) = binding

{- | Turn a verified handoff into child authority, checking that the child is
acting as the frame the binding actually named.

A frame that received someone else's (genuinely signed) handoff is refused here
rather than proceeding under a binding that does not describe it.
-}
authorizeChildProject ::
    VerifiedHandoff scope brokerGeneration ->
    -- | the frame this binary is actually running as
    Text ->
    ProjectVerb verb ->
    Either HandoffError (ChildPlanAuthority scope brokerGeneration)
authorizeChildProject handoff actualFrame verb
    | handoffChildFrame binding /= actualFrame =
        Left (HandoffFrameMismatch (handoffChildFrame binding) actualFrame)
    | handoffVerb binding /= projectVerbName verb =
        Left
            ( HandoffBindingMismatch
                ( "the handoff authorizes "
                    <> handoffVerb binding
                    <> ", not "
                    <> projectVerbName verb
                )
            )
    | otherwise = Right (ChildPlanAuthority binding)
  where
    binding = verifiedHandoffBinding handoff

-- ---------------------------------------------------------------------------
-- Digests and failures

{- | The digest a binding carries for its child config payload.

Exported because a parent must be able to compute it: 'mkHandoffOffer' requires
the binding's declared digest to describe the exact bytes being sent, so a
parent that could not derive this value could not build a legitimate offer at
all.
-}
childConfigDigest :: ByteString -> Text
childConfigDigest payload =
    Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 payload)))
  where
    hex byte = [hexDigit (byte `shiftR` 4), hexDigit (byte .&. 0x0f)]
    hexDigit nibble = ByteStringChar8.index "0123456789abcdef" (fromIntegral nibble)

-- | Every way a handoff can fail to authenticate.
data HandoffError
    = -- | expected at least this many bytes, saw this many
      HandoffWireTruncated Int Int
    | -- | the frame declared more bytes than a receiver will accept
      HandoffWireTooLarge Word64 Word64
    | -- | bytes remained after the last declared frame
      HandoffWireTrailingBytes Int
    | HandoffTokenInvalid Text
    | -- | this token has already been used
      HandoffTokenConsumed Text
    | HandoffSignatureInvalid Text
    | -- | expected digest, then the digest of the bytes received
      HandoffPayloadDigestMismatch Text Text
    | -- | the binding names this frame, but the binary is that one
      HandoffFrameMismatch Text Text
    | HandoffBindingMismatch Text
    | HandoffVerificationKeyUnavailable Text
    | HandoffStoreFailure ProtectedError
    deriving (Eq, Show)

-- | A one-line diagnostic.
handoffErrorMessage :: HandoffError -> String
handoffErrorMessage err = case err of
    HandoffWireTruncated expected actual ->
        "handoff: truncated wire (expected " <> show expected <> " bytes, saw " <> show actual <> ")"
    HandoffWireTooLarge declared limit ->
        "handoff: declared frame of " <> show declared <> " bytes exceeds the " <> show limit <> "-byte limit"
    HandoffWireTrailingBytes count ->
        "handoff: " <> show count <> " unexpected bytes after the last frame"
    HandoffTokenInvalid detail -> "handoff: invalid token: " <> Text.unpack detail
    HandoffTokenConsumed token ->
        "handoff: token " <> Text.unpack token <> " has already been consumed"
    HandoffSignatureInvalid detail -> "handoff: " <> Text.unpack detail
    HandoffPayloadDigestMismatch expected actual ->
        "handoff: payload digest " <> Text.unpack actual <> " does not match the bound " <> Text.unpack expected
    HandoffFrameMismatch bound actual ->
        "handoff: the grant binds frame " <> Text.unpack bound <> ", but this binary runs as " <> Text.unpack actual
    HandoffBindingMismatch detail -> "handoff: " <> Text.unpack detail
    HandoffVerificationKeyUnavailable detail ->
        "handoff: no usable verification key: " <> Text.unpack detail
    HandoffStoreFailure failure -> "handoff: " <> Text.unpack (protectedErrorMessage failure)

firstLine :: String -> Text
firstLine = Text.pack . takeWhile (/= '\n')
