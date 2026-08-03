{-# LANGUAGE GADTs #-}
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

* every handoff is bound to one exact 'HandoffBinding' — installed project,
  spec and config digests, payload kind, scope, plan revision, broker
  generation, parent→child frame edge, verb\/phase, and a commitment to the
  one-time token. Bindings are rendered with length-prefixed fields, so two
  different bindings cannot render to the same bytes;
* the **root** invocation owns the long-lived, independently installed project
  signing identity ('RootBroker'). Immediate parents get only a keyless
  'BrokerRelay': they can carry an offer and relay a grant request, and they
  cannot sign, delegate, or mint one themselves;
* the child's receiver mints a **fresh** 'HandoffChallenge' and the root signs
  over it, the exact framed token, the canonical binding, the signer identity,
  and the protocol domain\/version, so a recorded transcript cannot be replayed
  or spliced into another protocol;
* the offer's one-time token is consumed by a protected compare-and-swap at the
  root before the grant is issued. Child verification is deliberately
  stateless: a child store can never become the authority for a root token;
* verification recomputes the config digest from the bytes **actually
  received**, and takes the verification key as a separate installed input. A
  key carried in the envelope is never consulted.

Nothing here reads or writes @argv@ or the environment, and no value in this
module is representable in Dhall.
-}
module HostBootstrap.Handoff (
    -- * Bounded duplex protocol
    module HostBootstrap.Handoff.Protocol,

    -- * Length-delimited framing
    frameWire,
    unframeWire,
    maxWireBytes,
    handoffProtocolVersion,

    -- * The exact binding a handoff authenticates
    HandoffScope,
    productionHandoffScope,
    harnessHandoffScope,
    HandoffPayloadKind (..),
    HandoffBindingInput (..),
    HandoffBinding,
    mkHandoffBinding,
    handoffInstalledProject,
    handoffSpecDigest,
    handoffPayloadKind,
    handoffScope,
    handoffPlanRevision,
    handoffBrokerGeneration,
    handoffParentFrame,
    handoffChildFrame,
    handoffChildConfigDigest,
    handoffVerb,
    handoffPhase,
    handoffTokenCommitment,
    renderHandoffBinding,
    childConfigDigest,

    -- * Independently installed project identity
    ProjectSigningKey,
    projectSigningKeyFromBytes,
    installedProjectSigningKey,
    projectSigningVerificationKey,
    ProjectVerificationKey,
    installedVerificationKey,
    verificationKeyBytes,
    verificationKeyDigest,

    -- * The root broker and its keyless relay
    RootBroker,
    withRootBroker,
    rootBrokerVerificationKey,
    BrokerRelay,
    brokerRelay,
    relayBinding,

    -- * Offer, challenge, grant
    HandoffToken,
    freshHandoffToken,
    HandoffOffer,
    mkHandoffOffer,
    handoffOfferWire,
    handoffOfferBinding,
    HandoffChallenge,
    freshChallenge,
    challengeBytes,
    HandoffGrant,
    grantSignature,
    grantHandoff,

    -- * Verified results
    VerifiedHandoff,
    verifiedHandoffBinding,
    verifiedHandoffPayload,
    verifyHandoff,
    AuthenticatedConfigPayload,
    verifiedConfigPayload,
    authenticatedConfigDigest,
    authenticatedConfigBytes,
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
    InstalledProject,
    ProjectVerb,
    RootInvocationAuthority,
    brokerEpochWord,
    installedProjectName,
    projectVerbName,
    rootAuthorityEpoch,
    rootAuthorityProjectName,
    rootAuthorityVerb,
 )
import HostBootstrap.Config.Vocab (
    Harness,
    HarnessAuthority,
    Production,
    harnessRunName,
 )
import HostBootstrap.Handoff.Protocol
import HostBootstrap.Protected (
    Expectation (ExpectAbsent),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes),
    ProtectedSession,
    ProtectedStore,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    protectedErrorMessage,
    readProtectedRecord,
    withProtectedEntry,
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

-- | The protocol version included in every grant signature.
handoffProtocolVersion :: Word64
handoffProtocolVersion = 1

handoffGrantDomain :: ByteString
handoffGrantDomain = "hostbootstrap/handoff-grant"

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

{- | Opaque typed evidence for the exact config scope a root may hand off.

Production evidence comes from the installed project identity. Harness
evidence additionally requires the generative authority minted only by the
matching acquired Harness root. Callers never supply a descriptive scope tag.
-}
data HandoffScope scope where
    ProductionHandoffScope ::
        InstalledProject projectId ->
        HandoffScope (Production projectId)
    HarnessHandoffScope ::
        InstalledProject projectId ->
        HarnessAuthority projectId runId ->
        HandoffScope (Harness projectId runId)

-- | Narrow an installed project identity to Production handoff scope.
productionHandoffScope :: InstalledProject projectId -> HandoffScope (Production projectId)
productionHandoffScope = ProductionHandoffScope

-- | Narrow an acquired Harness root's authority to its exact run scope.
harnessHandoffScope ::
    InstalledProject projectId ->
    HarnessAuthority projectId runId ->
    HandoffScope (Harness projectId runId)
harnessHandoffScope = HarnessHandoffScope

handoffScopeProject :: HandoffScope scope -> Text
handoffScopeProject (ProductionHandoffScope project) = installedProjectName project
handoffScopeProject (HarnessHandoffScope project _) = installedProjectName project

handoffScopeTag :: HandoffScope scope -> Text
handoffScopeTag (ProductionHandoffScope _) = "Production"
handoffScopeTag (HarnessHandoffScope _ authority) = "Harness " <> harnessRunName authority

{- | The exact tuple a handoff token and grant are bound to.

Everything that distinguishes one legitimate handoff from another lives here, so
a grant for one edge cannot authorize a different one. In particular the
@parent -> child@ frame pair is part of the signed material: a sibling frame
cannot present a grant minted for its peer.
-}
data HandoffPayloadKind
    = NarrowedProjectConfig
    deriving (Eq, Ord, Show)

handoffPayloadKindName :: HandoffPayloadKind -> Text
handoffPayloadKindName NarrowedProjectConfig = "narrowed-project-config"

{- | Public, non-authorizing inputs for a handoff binding.

The token commitment is intentionally absent. 'mkHandoffBinding' derives it
from an opaque, freshly minted 'HandoffToken', so callers cannot accidentally
describe one token and transmit another.
-}
data HandoffBindingInput = HandoffBindingInput
    { requestedSpecDigest :: Text
    , requestedPayloadKind :: HandoffPayloadKind
    , requestedPlanRevision :: Text
    , requestedParentFrame :: Text
    , requestedChildFrame :: Text
    , requestedChildConfigDigest :: Text
    , requestedPhase :: Text
    }
    deriving (Eq, Show)

data HandoffBinding scope brokerGeneration = HandoffBinding
    { handoffInstalledProject :: Text
    , handoffSpecDigest :: Text
    , handoffPayloadKind :: HandoffPayloadKind
    , handoffScope :: Text
    -- ^ the descriptive scope tag (@Production@ or @Harness \<runId\>@)
    , handoffPlanRevision :: Text
    , handoffBrokerGeneration :: Word64
    , handoffParentFrame :: Text
    , handoffChildFrame :: Text
    , handoffChildConfigDigest :: Text
    , handoffVerb :: Text
    , handoffPhase :: Text
    , handoffTokenCommitment :: Text
    }
    deriving (Eq)

instance Show (HandoffBinding scope brokerGeneration) where
    show binding =
        "HandoffBinding {project = "
            <> show (handoffInstalledProject binding)
            <> ", payloadKind = "
            <> show (handoffPayloadKind binding)
            <> ", parentFrame = "
            <> show (handoffParentFrame binding)
            <> ", childFrame = "
            <> show (handoffChildFrame binding)
            <> ", verb = "
            <> show (handoffVerb binding)
            <> ", phase = "
            <> show (handoffPhase binding)
            <> ", digests = <redacted>, token = <redacted>}"

-- | Build the canonical binding for one freshly minted token.
mkHandoffBinding ::
    RootBroker scope brokerGeneration verb ->
    HandoffBindingInput ->
    HandoffToken ->
    Either HandoffError (HandoffBinding scope brokerGeneration)
mkHandoffBinding broker input token = do
    requireBindingField "spec digest" (requestedSpecDigest input)
    requireBindingField "plan revision" (requestedPlanRevision input)
    requireBindingField "parent frame" (requestedParentFrame input)
    requireBindingField "child frame" (requestedChildFrame input)
    requireBindingField "child config digest" (requestedChildConfigDigest input)
    requireBindingField "phase" (requestedPhase input)
    pure
        HandoffBinding
            { handoffInstalledProject = brokerProjectName broker
            , handoffSpecDigest = requestedSpecDigest input
            , handoffPayloadKind = requestedPayloadKind input
            , handoffScope = brokerScopeTag broker
            , handoffPlanRevision = requestedPlanRevision input
            , handoffBrokerGeneration = brokerEpochValue broker
            , handoffParentFrame = requestedParentFrame input
            , handoffChildFrame = requestedChildFrame input
            , handoffChildConfigDigest = requestedChildConfigDigest input
            , handoffVerb = brokerVerbName broker
            , handoffPhase = requestedPhase input
            , handoffTokenCommitment = tokenCommitment token
            }

requireBindingField :: Text -> Text -> Either HandoffError ()
requireBindingField name value
    | Text.null value = Left (HandoffBindingMismatch (name <> " must not be empty"))
    | otherwise = Right ()

{- | Canonical bytes for a binding.

Each field is length-prefixed rather than separator-joined. With a separator, a
parent frame named @"a-b"@ and child @"c"@ would render identically to parent
@"a"@ and child @"b-c"@, and one grant would authenticate two different edges.
Length prefixes make the field boundaries unambiguous.
-}
renderHandoffBinding :: HandoffBinding scope brokerGeneration -> ByteString
renderHandoffBinding binding =
    ByteString.concat
        [ field (handoffInstalledProject binding)
        , field (handoffSpecDigest binding)
        , field (handoffPayloadKindName (handoffPayloadKind binding))
        , field (handoffScope binding)
        , field (handoffPlanRevision binding)
        , frameWire (ByteString.pack (word64BigEndian (handoffBrokerGeneration binding)))
        , field (handoffParentFrame binding)
        , field (handoffChildFrame binding)
        , field (handoffChildConfigDigest binding)
        , field (handoffVerb binding)
        , field (handoffPhase binding)
        , field (handoffTokenCommitment binding)
        ]
  where
    field = frameWire . TextEncoding.encodeUtf8

-- ---------------------------------------------------------------------------
-- Keys

{- | The root-only, long-lived project signing identity.

Its constructor and bytes are deliberately hidden. Provisioning code may load
the 32-byte Ed25519 seed from a protected file or validate provisioned bytes;
the receiving binary independently installs only the corresponding public key.
The offer and grant never carry either key.
-}
newtype ProjectSigningKey = ProjectSigningKey Ed25519.SecretKey

instance Show ProjectSigningKey where
    show _ = "ProjectSigningKey <redacted>"

-- | Validate a provisioned 32-byte Ed25519 signing seed.
projectSigningKeyFromBytes :: ByteString -> Either HandoffError ProjectSigningKey
projectSigningKeyFromBytes raw = case Ed25519.secretKey raw of
    CryptoFailed _ -> Left HandoffSigningKeyInvalid
    CryptoPassed key -> Right (ProjectSigningKey key)

{- | Load the root-only signing seed. Missing, unreadable, and malformed files
are typed refusals, and diagnostics never contain the file's contents.
-}
installedProjectSigningKey :: FilePath -> IO (Either HandoffError ProjectSigningKey)
installedProjectSigningKey path = do
    present <- doesFileExist path
    if not present
        then pure (Left (HandoffSigningKeyUnavailable ("no installed signing key at " <> Text.pack path)))
        else do
            loaded <- try (ByteString.readFile path) :: IO (Either SomeException ByteString)
            pure $ case loaded of
                Left err ->
                    Left
                        ( HandoffSigningKeyUnavailable
                            ("failed to read " <> Text.pack path <> ": " <> firstLine (show err))
                        )
                Right raw -> projectSigningKeyFromBytes raw

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

-- | Stable identity of the independently installed public key.
verificationKeyDigest :: ProjectVerificationKey -> Text
verificationKeyDigest = digestBytes . verificationKeyBytes

-- | Derive the public half for independent installation.
projectSigningVerificationKey :: ProjectSigningKey -> ProjectVerificationKey
projectSigningVerificationKey (ProjectSigningKey secret) =
    ProjectVerificationKey (Ed25519.toPublic secret)

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
    , brokerProjectName :: Text
    , brokerScopeTag :: Text
    , brokerProtectedStore :: ProtectedStore
    }

instance Show (RootBroker scope brokerGeneration verb) where
    show broker = "RootBroker <signing> " <> show (brokerEpochValue broker)

-- | The public half a child binary must have installed to verify this broker.
rootBrokerVerificationKey :: RootBroker scope brokerGeneration verb -> ProjectVerificationKey
rootBrokerVerificationKey = ProjectVerificationKey . brokerPublic

{- | Run an action with the independently provisioned project signer, narrowed
to one verified root invocation's project, epoch, and verb.

The resulting broker exists only inside the continuation. Unlike the previous
ephemeral-key design, a child can authenticate it against a public key that was
installed independently of this invocation and its handoff envelope.
-}
withRootBroker ::
    HandoffScope scope ->
    ProtectedStore ->
    ProjectSigningKey ->
    RootInvocationAuthority scope brokerGeneration verb ->
    (RootBroker scope brokerGeneration verb -> IO result) ->
    IO (Either HandoffError result)
withRootBroker scope store (ProjectSigningKey secret) root use
    | handoffScopeProject scope /= rootAuthorityProjectName root =
        pure (Left (HandoffBindingMismatch "the scope evidence names a different installed project than the root authority"))
    | otherwise =
        Right
            <$> use
                RootBroker
                    { brokerSecret = secret
                    , brokerPublic = Ed25519.toPublic secret
                    , brokerEpochValue = brokerEpochWord (rootAuthorityEpoch root)
                    , brokerVerbName = projectVerbName (rootAuthorityVerb root)
                    , brokerProjectName = rootAuthorityProjectName root
                    , brokerScopeTag = handoffScopeTag scope
                    , brokerProtectedStore = store
                    }

{- | What an immediate parent is given: the binding it may carry, and nothing
else.

There is deliberately no field here from which a signature can be produced. A
parent relays; the root signs.
-}
newtype BrokerRelay scope brokerGeneration =
    BrokerRelay (HandoffBinding scope brokerGeneration)
    deriving (Eq, Show)

-- | Hand a parent the relay for one edge.
brokerRelay ::
    RootBroker scope brokerGeneration verb ->
    HandoffBinding scope brokerGeneration ->
    Either HandoffError (BrokerRelay scope brokerGeneration)
brokerRelay broker binding
    | handoffInstalledProject binding /= brokerProjectName broker =
        Left
            ( HandoffBindingMismatch
                "the binding names a different installed project than the live root broker"
            )
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
relayBinding :: BrokerRelay scope brokerGeneration -> HandoffBinding scope brokerGeneration
relayBinding (BrokerRelay binding) = binding

-- ---------------------------------------------------------------------------
-- Offer, challenge, grant

{- | An unpredictable, fixed-width one-time token minted by the root side.

There is no textual constructor or byte accessor. The only public operation
that emits it is 'handoffOfferWire', which frames it for the authenticated
protocol. Its 'Show' instance is permanently redacted.
-}
newtype HandoffToken = HandoffToken ByteString
    deriving (Eq)

instance Show HandoffToken where
    show _ = "HandoffToken <redacted>"

-- | Mint a cryptographically fresh protocol-v1 token.
freshHandoffToken :: IO HandoffToken
freshHandoffToken = HandoffToken <$> (getRandomBytes tokenBytesLength :: IO ByteString)

tokenBytesLength :: Int
tokenBytesLength = 32

tokenFrame :: HandoffToken -> ByteString
tokenFrame (HandoffToken token) = frameWire token

tokenCommitment :: HandoffToken -> Text
tokenCommitment = digestBytes . tokenFrame

{- | What crosses the boundary: the length-delimited narrowed config wire plus
the one-time token identifying this handoff.

The payload is carried as bytes and the token is a separate framed field, so the
receiver never has to parse config to find where the token starts.
-}
data HandoffOffer scope brokerGeneration = HandoffOffer
    { offerBinding :: HandoffBinding scope brokerGeneration
    , offerPayload :: ByteString
    , offerToken :: HandoffToken
    }
    deriving (Eq)

instance Show (HandoffOffer scope brokerGeneration) where
    show offer =
        "HandoffOffer {binding = "
            <> show (offerBinding offer)
            <> ", payload = <redacted>, token = <redacted>}"

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
    HandoffToken ->
    Either HandoffError (HandoffOffer scope brokerGeneration)
mkHandoffOffer (BrokerRelay binding) payload token
    | handoffTokenCommitment binding /= tokenCommitment token =
        Left
            ( HandoffBindingMismatch
                "the binding's token commitment does not describe the offered token"
            )
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

{- | The framed bytes an offer transmits: exact config bytes, exact token, then
the canonical binding. Including the binding lets a real receiver compare what
arrived with the edge it independently expects; it need not obtain that binding
from an ambient config or command-line argument.
-}
handoffOfferWire :: HandoffOffer scope brokerGeneration -> ByteString
handoffOfferWire offer =
    frameWire (offerPayload offer)
        <> tokenFrame (offerToken offer)
        <> frameWire (renderHandoffBinding (offerBinding offer))

-- | The binding an offer claims. Descriptive until a grant authenticates it.
handoffOfferBinding ::
    HandoffOffer scope brokerGeneration ->
    HandoffBinding scope brokerGeneration
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
newtype HandoffGrant scope brokerGeneration = HandoffGrant ByteString
    deriving (Eq)

instance Show (HandoffGrant scope brokerGeneration) where
    show _ = "HandoffGrant <signed>"

-- | The raw signature bytes, for transmission.
grantSignature :: HandoffGrant scope brokerGeneration -> ByteString
grantSignature (HandoffGrant value) = value

{- | Consume one token at the root and issue its grant.

The broker opens the exact root protected store captured when the typed root
and scope evidence minted it. The first request publishes only a digest of the
signed transcript. Repeating the identical request is idempotent and yields the
same deterministic Ed25519 signature; any other challenge or transcript for
the token is refused. There is intentionally no public pure signing function
and no caller-selected store argument.
-}
grantHandoff ::
    RootBroker scope brokerGeneration verb ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    IO (Either HandoffError (HandoffGrant scope brokerGeneration))
grantHandoff broker offer challenge =
    case brokerRelay broker binding of
        Left failure -> pure (Left failure)
        Right _ -> do
            entered <-
                withProtectedEntry (brokerProtectedStore broker) $ \session ->
                    Right <$> consumeTokenAtRoot session binding material
            pure $ case entered of
                Left failure -> Left (HandoffStoreFailure failure)
                Right (Left failure) -> Left failure
                Right (Right ()) -> Right (issueGrant broker material)
  where
    binding = handoffOfferBinding offer
    material =
        signedMaterial
            (rootBrokerVerificationKey broker)
            binding
            (tokenFrame (offerToken offer))
            challenge

issueGrant ::
    RootBroker scope brokerGeneration verb ->
    ByteString ->
    HandoffGrant scope brokerGeneration
issueGrant broker material =
    HandoffGrant
        ( convert
            ( Ed25519.sign
                (brokerSecret broker)
                (brokerPublic broker)
                material
            )
        )

{- | Exactly what a signature covers, in protocol order.

The token argument is already its exact wire frame. Every other variable-width
component is length-framed, and the protocol version is fixed-width. This is
both canonical and domain separated from every other Ed25519 use in the
project.
-}
signedMaterial ::
    ProjectVerificationKey ->
    HandoffBinding scope brokerGeneration ->
    ByteString ->
    HandoffChallenge ->
    ByteString
signedMaterial key binding exactTokenFrame (HandoffChallenge challenge) =
    ByteString.concat
        [ frameWire handoffGrantDomain
        , frameWire (ByteString.pack (word64BigEndian handoffProtocolVersion))
        , frameWire (TextEncoding.encodeUtf8 (verificationKeyDigest key))
        , frameWire (renderHandoffBinding binding)
        , exactTokenFrame
        , frameWire challenge
        ]

-- ---------------------------------------------------------------------------
-- Verification

{- | An authenticated handoff. Minted only by 'verifyHandoff'; the constructor
is private, so raw wire cannot be promoted into one.
-}
data VerifiedHandoff scope brokerGeneration = VerifiedHandoff
    { verifiedBinding :: HandoffBinding scope brokerGeneration
    , verifiedPayload :: ByteString
    }

instance Show (VerifiedHandoff scope brokerGeneration) where
    show handoff = "VerifiedHandoff " <> show (verifiedBinding handoff)

-- | The authenticated binding.
verifiedHandoffBinding ::
    VerifiedHandoff scope brokerGeneration ->
    HandoffBinding scope brokerGeneration
verifiedHandoffBinding = verifiedBinding

-- | The exact bytes whose digest the signature covered.
verifiedHandoffPayload :: VerifiedHandoff scope brokerGeneration -> ByteString
verifiedHandoffPayload = verifiedPayload

{- | An opaque witness that exact config bytes were authenticated under a
binding whose payload kind is 'NarrowedProjectConfig'. This is the narrow seam
for config admission: it carries neither the handoff token nor a protected-store
capability.
-}
data AuthenticatedConfigPayload scope brokerGeneration = AuthenticatedConfigPayload
    { authenticatedBinding :: HandoffBinding scope brokerGeneration
    , authenticatedBytes :: ByteString
    }

instance Show (AuthenticatedConfigPayload scope brokerGeneration) where
    show payload =
        "AuthenticatedConfigPayload {binding = "
            <> show (authenticatedBinding payload)
            <> ", bytes = <redacted>}"

-- | Narrow a verified handoff to the config-admission witness.
verifiedConfigPayload ::
    VerifiedHandoff scope brokerGeneration ->
    Either HandoffError (AuthenticatedConfigPayload scope brokerGeneration)
verifiedConfigPayload handoff
    | handoffPayloadKind binding == NarrowedProjectConfig =
        Right
            AuthenticatedConfigPayload
                { authenticatedBinding = binding
                , authenticatedBytes = verifiedHandoffPayload handoff
                }
    | otherwise = Left (HandoffBindingMismatch "the authenticated payload is not a project config")
  where
    binding = verifiedHandoffBinding handoff

-- | The signed digest of the exact authenticated config bytes.
authenticatedConfigDigest :: AuthenticatedConfigPayload scope brokerGeneration -> Text
authenticatedConfigDigest = handoffChildConfigDigest . authenticatedBinding

-- | The exact authenticated bytes for atomic config admission.
authenticatedConfigBytes :: AuthenticatedConfigPayload scope brokerGeneration -> ByteString
authenticatedConfigBytes = authenticatedBytes

{- | Statelessly verify one received handoff.

The token was authoritatively consumed by 'grantHandoff' in the root protected
store before this grant could exist. The child neither receives nor accepts a
store capability here. It recomputes the config digest and token commitment
from the exact received frames, requires the transmitted canonical binding to
match the independently expected binding, and takes its key as a separate
installed input — never from the message.
-}
verifyHandoff ::
    ProjectVerificationKey ->
    -- | the exact framed bytes received
    ByteString ->
    -- | the binding the receiver expects for its own edge
    HandoffBinding scope brokerGeneration ->
    HandoffChallenge ->
    HandoffGrant scope brokerGeneration ->
    Either HandoffError (VerifiedHandoff scope brokerGeneration)
verifyHandoff installedKey@(ProjectVerificationKey key) received expected challenge (HandoffGrant signature) =
    case decodeOfferWire received of
        Left err -> Left err
        Right (payload, token, receivedBinding)
            | childConfigDigest payload /= handoffChildConfigDigest expected ->
                Left
                    ( HandoffPayloadDigestMismatch
                        (handoffChildConfigDigest expected)
                        (childConfigDigest payload)
                    )
            | tokenCommitment token /= handoffTokenCommitment expected ->
                Left (HandoffBindingMismatch "the received token does not match the bound token commitment")
            | receivedBinding /= renderHandoffBinding expected ->
                Left (HandoffBindingMismatch "the received canonical binding is not the expected edge binding")
            | otherwise -> case Ed25519.signature signature of
                CryptoFailed _ -> Left HandoffSignatureInvalid
                CryptoPassed parsed
                    | not
                        ( Ed25519.verify
                            key
                            (signedMaterial installedKey expected (tokenFrame token) challenge)
                            parsed
                        ) -> Left HandoffSignatureInvalid
                    | otherwise ->
                        Right
                            VerifiedHandoff
                                { verifiedBinding = expected
                                , verifiedPayload = payload
                                }

{- | Split the received wire into its three framed fields. A message with a
missing frame, a non-v1 token width, or trailing bytes is refused.
-}
decodeOfferWire :: ByteString -> Either HandoffError (ByteString, HandoffToken, ByteString)
decodeOfferWire raw = do
    (payload, afterPayload) <- takeFrame raw
    (tokenBytes, afterToken) <- takeFrame afterPayload
    (bindingBytes, trailing) <- takeFrame afterToken
    if ByteString.length tokenBytes /= tokenBytesLength
        then Left HandoffTokenInvalid
        else
            if not (ByteString.null trailing)
                then Left (HandoffWireTrailingBytes (ByteString.length trailing))
                else Right (payload, HandoffToken tokenBytes, bindingBytes)

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

{- | Burn the token in the root store. An identical retry observes the same
transcript digest and succeeds without advancing the record version.
-}
consumeTokenAtRoot ::
    ProtectedSession session ->
    HandoffBinding scope brokerGeneration ->
    ByteString ->
    IO (Either HandoffError ())
consumeTokenAtRoot session binding material =
    case mkRecordKey (tokenRecordKey binding) of
        Left failure -> pure (Left (HandoffStoreFailure failure))
        Right key -> do
            observed <- readProtectedRecord session key
            case observed of
                Left failure -> pure (Left (HandoffStoreFailure failure))
                Right (Just record)
                    | protectedRecordBytes record == transcriptDigest -> pure (Right ())
                    | otherwise -> pure (Left HandoffTokenConsumed)
                Right Nothing -> do
                    written <-
                        compareAndSwapProtectedRecord
                            session
                            key
                            ExpectAbsent
                            transcriptDigest
                    case written of
                        Right _ -> pure (Right ())
                        Left writeFailure -> do
                            raced <- readProtectedRecord session key
                            pure $ case raced of
                                Right (Just record)
                                    | protectedRecordBytes record == transcriptDigest -> Right ()
                                    | otherwise -> Left HandoffTokenConsumed
                                Right Nothing -> Left (HandoffStoreFailure writeFailure)
                                Left readFailure -> Left (HandoffStoreFailure readFailure)
  where
    transcriptDigest = TextEncoding.encodeUtf8 (digestBytes material)

tokenRecordKey :: HandoffBinding scope brokerGeneration -> Text
tokenRecordKey binding = "handoff-token." <> handoffTokenCommitment binding

-- ---------------------------------------------------------------------------
-- Child authority

{- | What a verified handoff earns the child: permission to act at its own
frame, for the exact verb and phase the root bound.

It deliberately carries no signing key and no root authority. A child that needs
a grandchild grant must ask the root relay for one; it cannot mint it.
-}
newtype ChildPlanAuthority scope brokerGeneration =
    ChildPlanAuthority (HandoffBinding scope brokerGeneration)

instance Show (ChildPlanAuthority scope brokerGeneration) where
    show (ChildPlanAuthority binding) = "ChildPlanAuthority " <> show binding

-- | The authenticated binding this authority acts under.
childPlanAuthorityBinding ::
    ChildPlanAuthority scope brokerGeneration ->
    HandoffBinding scope brokerGeneration
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
childConfigDigest = digestBytes

digestBytes :: ByteString -> Text
digestBytes bytes =
    Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 bytes)))
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
    | HandoffTokenInvalid
    | -- | this token has already been used
      HandoffTokenConsumed
    | HandoffSignatureInvalid
    | -- | expected digest, then the digest of the bytes received
      HandoffPayloadDigestMismatch Text Text
    | -- | the binding names this frame, but the binary is that one
      HandoffFrameMismatch Text Text
    | HandoffBindingMismatch Text
    | HandoffSigningKeyInvalid
    | HandoffSigningKeyUnavailable Text
    | HandoffVerificationKeyUnavailable Text
    | HandoffStoreFailure ProtectedError
    deriving (Eq)

instance Show HandoffError where
    show = handoffErrorMessage

-- | A one-line diagnostic.
handoffErrorMessage :: HandoffError -> String
handoffErrorMessage err = case err of
    HandoffWireTruncated expected actual ->
        "handoff: truncated wire (expected " <> show expected <> " bytes, saw " <> show actual <> ")"
    HandoffWireTooLarge declared limit ->
        "handoff: declared frame of " <> show declared <> " bytes exceeds the " <> show limit <> "-byte limit"
    HandoffWireTrailingBytes count ->
        "handoff: " <> show count <> " unexpected bytes after the last frame"
    HandoffTokenInvalid -> "handoff: invalid one-time token"
    HandoffTokenConsumed -> "handoff: one-time token has already authorized another transcript"
    HandoffSignatureInvalid -> "handoff: the grant signature is invalid for this transcript"
    HandoffPayloadDigestMismatch expected actual ->
        "handoff: payload digest " <> Text.unpack actual <> " does not match the bound " <> Text.unpack expected
    HandoffFrameMismatch bound actual ->
        "handoff: the grant binds frame " <> Text.unpack bound <> ", but this binary runs as " <> Text.unpack actual
    HandoffBindingMismatch detail -> "handoff: " <> Text.unpack detail
    HandoffSigningKeyInvalid -> "handoff: the installed signing key is malformed"
    HandoffSigningKeyUnavailable detail ->
        "handoff: no usable signing key: " <> Text.unpack detail
    HandoffVerificationKeyUnavailable detail ->
        "handoff: no usable verification key: " <> Text.unpack detail
    HandoffStoreFailure failure -> "handoff: " <> Text.unpack (protectedErrorMessage failure)

firstLine :: String -> Text
firstLine = Text.pack . takeWhile (/= '\n')
