{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The parent half of the authenticated handoff, and the duplex relay that
lets a frame which cannot sign still hand authority downward
(§ X, § EE, the authenticated-handoff-and-child-admission phase).

Two capabilities are needed to hand an edge to a child: someone must **open**
it — durably record that this exact edge is one the root intends — and someone
must **grant** it, signing over the challenge the child mints. Both belong to
the root. A 'BrokerLink' is how a frame reaches them:

* at the root, 'rootBrokerLink' holds the live 'RootBroker' and an admission
  predicate naming which edges its plan contains, so the root opens the edges it
  planned and no others;
* at every other frame, 'relayedBrokerLink' holds a channel and a request
  identity — and nothing else. It is *structurally* keyless: there is no field a
  signature could come out of, and no function from it to a 'RootBroker'. It
  forwards, waits, and passes the answer on.

The recursion is what makes one shape serve every depth. 'offerHandoffEdge'
opens an edge through its link, offers it to the child, and then stays on the
channel serving whatever the child relays upward — which, at an intermediate
frame, it satisfies by relaying further up its own link. So a request raised at
the innermost frame walks outward to the root and its answer walks back, with
each frame in between holding no more than a pipe.
-}
module HostBootstrap.Handoff.Relay (
    -- * Reaching the root
    BrokerLink,
    rootBrokerLink,
    relayedBrokerLink,
    EdgeAdmission,
    openEdgeThroughLink,
    grantThroughLink,

    -- * Handing an edge to a child
    offerHandoffEdge,

    -- * Failures
    RelayError (..),
    relayErrorMessage,
) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Handoff (
    BrokerRelay,
    HandoffBindingInput,
    HandoffChallenge,
    HandoffError,
    HandoffGrant,
    HandoffOffer,
    HandoffToken,
    ProjectVerificationKey,
    RootBroker,
    brokerRelayFromWire,
    challengeBytes,
    frameWire,
    grantHandoff,
    grantSignature,
    handoffBindingInputFromWire,
    handoffChallengeFromBytes,
    handoffErrorMessage,
    handoffGrantFromSignature,
    handoffOfferFrames,
    handoffTokenBytes,
    handoffTokenFromBytes,
    mkHandoffOffer,
    registerHandoffEdge,
    relayBinding,
    renderHandoffBinding,
    renderHandoffBindingInput,
    takeHandoffFrame,
    verificationKeyDigest,
 )
import HostBootstrap.Handoff.Protocol (
    HandoffChannel,
    ProtocolError,
    ProtocolMessage,
    ProtocolTag (
        AcceptedTag,
        ChallengeTag,
        CompletedTag,
        GrantRequestTag,
        GrantResponseTag,
        GrantTag,
        OfferRequestTag,
        OfferResponseTag,
        OfferTag,
        RefusedTag
    ),
    channelReceive,
    channelSend,
    protocolErrorMessage,
    protocolMessage,
    protocolMessageFields,
    protocolMessageTag,
 )

-- ---------------------------------------------------------------------------
-- Reaching the root

{- | Which edges a root will open.

The root re-derives project, scope, generation, and verb from its own typed
evidence, so a request can only influence the frames, phase, and digests. Those
still matter: without this predicate a root would sign for any well-formed edge
it was asked about, and relaying would be signing one message removed. The plan
that knows which descents exist supplies the answer.

It answers in @IO@ because the thing that knows is the live plan and its durable
state, not a table a caller can fold into a pure function.
-}
type EdgeAdmission = HandoffBindingInput -> IO (Either Text ())

{- | A frame's route to the root's two capabilities.

Opaque, and deliberately so: the two constructors below are the only ways to
build one, and only one of them has a key behind it.
-}
data BrokerLink scope brokerGeneration = BrokerLink
    { linkOpen ::
        HandoffBindingInput ->
        IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken))
    , linkGrant ::
        HandoffOffer scope brokerGeneration ->
        HandoffChallenge ->
        IO (Either RelayError (HandoffGrant scope brokerGeneration))
    , linkKeyDigest :: ByteString
    }

instance Show (BrokerLink scope brokerGeneration) where
    show _ = "BrokerLink <to root>"

{- | The root frame's own link: it opens edges its plan admits, and signs.

This is the only 'BrokerLink' with a signing capability behind it, and the
'RootBroker' that supplies it exists only inside @withRootBroker@ — so the link
cannot outlive the invocation that earned it.
-}
rootBrokerLink ::
    RootBroker scope brokerGeneration verb ->
    ProjectVerificationKey ->
    EdgeAdmission ->
    BrokerLink scope brokerGeneration
rootBrokerLink broker key admits =
    BrokerLink
        { linkOpen = \input -> do
            admitted <- admits input
            case admitted of
                Left reason -> pure (Left (RelayEdgeNotPlanned reason))
                Right () ->
                    fmap
                        (either (Left . RelayHandoffFailure) Right)
                        (registerHandoffEdge broker input)
        , linkGrant = \offer challenge ->
            fmap (either (Left . RelayHandoffFailure) Right) (grantHandoff broker offer challenge)
        , linkKeyDigest = TextEncoding.encodeUtf8 (verificationKeyDigest key)
        }

{- | Every other frame's link: a channel upward and the request identity its own
admission runs under.

There is no key here and no path to one. A frame holding this can ask the root
to open an edge and ask it to grant one; it cannot do either itself, and it
cannot delegate the ability to a frame below it, because what it passes down is
another channel.
-}
relayedBrokerLink ::
    HandoffChannel ->
    Word64 ->
    -- | the verification key this frame installed, whose digest it advertises
    ProjectVerificationKey ->
    BrokerLink scope brokerGeneration
relayedBrokerLink channel request key =
    BrokerLink
        { linkOpen = relayOpen channel request
        , linkGrant = relayGrant channel request
        , linkKeyDigest = TextEncoding.encodeUtf8 (verificationKeyDigest key)
        }

relayOpen ::
    HandoffChannel ->
    Word64 ->
    HandoffBindingInput ->
    IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken))
relayOpen channel request input = do
    sent <- transmit channel OfferRequestTag request [renderHandoffBindingInput input]
    case sent of
        Left failure -> pure (Left failure)
        Right () -> do
            answer <- await channel OfferResponseTag
            pure (answer >>= adoptOpenedEdge)

adoptOpenedEdge ::
    [ByteString] ->
    Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken)
adoptOpenedEdge [payload] = do
    (bindingBytes, tokenFrame) <- splitPair payload
    relay <- fromHandoff (brokerRelayFromWire bindingBytes)
    token <- fromHandoff (handoffTokenFromBytes tokenFrame)
    pure (relay, token)
adoptOpenedEdge fields = Left (RelayMalformedMessage OfferResponseTag (length fields))

{- | Ask this frame's route to the root to open one edge.

At the root this registers it durably; anywhere else it is a request that walks
outward. The two are the same operation from the caller's side, which is what
makes one descent implementation serve every frame.
-}
openEdgeThroughLink ::
    BrokerLink scope brokerGeneration ->
    HandoffBindingInput ->
    IO (Either RelayError (BrokerRelay scope brokerGeneration, HandoffToken))
openEdgeThroughLink = linkOpen

{- | Ask this frame's route to the root to authenticate one offer against one
challenge.

Only the root signs. Everywhere else this is a message with a reply, and the
reply's signature was produced by a key this frame never had.
-}
grantThroughLink ::
    BrokerLink scope brokerGeneration ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    IO (Either RelayError (HandoffGrant scope brokerGeneration))
grantThroughLink = linkGrant

relayGrant ::
    HandoffChannel ->
    Word64 ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    IO (Either RelayError (HandoffGrant scope brokerGeneration))
relayGrant channel request offer challenge = do
    sent <-
        transmit
            channel
            GrantRequestTag
            request
            [offerWireOf offer, challengeBytes challenge]
    case sent of
        Left failure -> pure (Left failure)
        Right () -> do
            answer <- await channel GrantResponseTag
            pure $ case answer of
                Left failure -> Left failure
                Right [signature] -> Right (handoffGrantFromSignature signature)
                Right fields -> Left (RelayMalformedMessage GrantResponseTag (length fields))

-- ---------------------------------------------------------------------------
-- Handing an edge to a child

{- | Open one edge through this frame's link, offer it to the child on
@channel@, and stay on the channel until the child is done.

The tail of this function is the duplex half. After the child accepts, it keeps
the channel and may relay requests of its own — it is the parent of the next
frame — so this loop answers them through the *same* link that opened this edge.
At the root that means signing; at an intermediate frame it means relaying one
hop further up. Either way the frame in the middle only ever moves messages.
-}
offerHandoffEdge ::
    BrokerLink scope brokerGeneration ->
    -- | the channel to the child this frame is launching
    HandoffChannel ->
    -- | the request identity for this edge
    Word64 ->
    HandoffBindingInput ->
    -- | the exact narrowed child config bytes
    ByteString ->
    IO (Either RelayError ())
offerHandoffEdge link channel request input payload = do
    opened <- linkOpen link input
    case opened of
        -- The child has been launched and is already waiting on its first
        -- message, so a failure here is announced rather than left to expire as
        -- a closed pipe: "the plan names no such edge" is a diagnosis, and an
        -- EOF is not.
        Left failure -> refuse channel request failure
        Right (relay, token) -> case mkHandoffOffer relay payload token of
            Left failure -> refuse channel request (RelayHandoffFailure failure)
            Right offer -> do
                sent <-
                    transmit
                        channel
                        OfferTag
                        request
                        (offerFieldsOf offer (linkKeyDigest link))
                case sent of
                    Left failure -> pure (Left failure)
                    Right () -> awaitChallenge link channel request offer

awaitChallenge ::
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    HandoffOffer scope brokerGeneration ->
    IO (Either RelayError ())
awaitChallenge link channel request offer = do
    answer <- await channel ChallengeTag
    case answer of
        Left failure -> pure (Left failure)
        Right [raw] -> case handoffChallengeFromBytes raw of
            Left failure -> pure (Left (RelayHandoffFailure failure))
            Right challenge -> do
                granted <- linkGrant link offer challenge
                case granted of
                    Left failure -> do
                        -- The child is waiting on an answer it will never get,
                        -- so tell it rather than letting its read block until
                        -- the pipe closes.
                        _ <- refuse channel request failure
                        pure (Left failure)
                    Right grant -> do
                        sent <-
                            transmit
                                channel
                                GrantTag
                                request
                                [grantSignature grant, linkKeyDigest link]
                        case sent of
                            Left failure -> pure (Left failure)
                            Right () -> serveUntilDone link channel request
        Right fields -> pure (Left (RelayMalformedMessage ChallengeTag (length fields)))

{- | Read the child's acceptance and then serve it until it completes.

A child that refuses at any point ends the exchange with its own cause, which is
returned rather than turned into a generic transport failure: "the child
declined" and "the pipe broke" are different facts.
-}
serveUntilDone ::
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    IO (Either RelayError ())
serveUntilDone link channel request = do
    next <- receive channel
    case next of
        Left failure -> pure (Left failure)
        Right message -> case protocolMessageTag message of
            AcceptedTag -> serveUntilDone link channel request
            CompletedTag -> pure (Right ())
            RefusedTag -> pure (Left (refusalFrom message))
            OfferRequestTag -> do
                served <- serveOpen link channel request message
                either (pure . Left) (const (serveUntilDone link channel request)) served
            GrantRequestTag -> do
                served <- serveGrant link channel request message
                either (pure . Left) (const (serveUntilDone link channel request)) served
            tag -> pure (Left (RelayUnexpectedMessage tag))

-- | Answer a child's request to open an edge, through this frame's own link.
serveOpen ::
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ProtocolMessage ->
    IO (Either RelayError ())
serveOpen link channel request message = case protocolMessageFields message of
    [raw] -> case handoffBindingInputFromWire raw of
        Left failure -> refuse channel request (RelayHandoffFailure failure)
        Right input -> do
            opened <- linkOpen link input
            case opened of
                Left failure -> refuse channel request failure
                Right (relay, token) ->
                    transmit
                        channel
                        OfferResponseTag
                        request
                        [ frameWire (renderHandoffBinding (relayBinding relay))
                            <> frameWire (handoffTokenBytes token)
                        ]
    fields -> refuse channel request (RelayMalformedMessage OfferRequestTag (length fields))

-- | Answer a child's request for a grant, through this frame's own link.
serveGrant ::
    BrokerLink scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ProtocolMessage ->
    IO (Either RelayError ())
serveGrant link channel request message = case protocolMessageFields message of
    [offerWire, challengeRaw] -> case adoptRelayedRequest offerWire challengeRaw of
        Left failure -> refuse channel request failure
        Right (offer, challenge) -> do
            granted <- linkGrant link offer challenge
            case granted of
                Left failure -> refuse channel request failure
                Right grant ->
                    transmit channel GrantResponseTag request [grantSignature grant]
    fields -> refuse channel request (RelayMalformedMessage GrantRequestTag (length fields))

{- | Rebuild the offer and challenge a relayed request describes.

The binding is adopted as a relay and then re-paired with the exact payload and
token that travelled with it, so what this frame passes upward is the same edge
the requester holds and not a re-description of it. Whether that edge is one the
root opened is the root's question, answered where the durable record lives.
-}
adoptRelayedRequest ::
    ByteString ->
    ByteString ->
    Either RelayError (HandoffOffer scope brokerGeneration, HandoffChallenge)
adoptRelayedRequest offerWire challengeRaw = do
    (payload, afterPayload) <- fromHandoff (takeHandoffFrame offerWire)
    (tokenFrame, afterToken) <- fromHandoff (takeHandoffFrame afterPayload)
    (bindingBytes, trailing) <- fromHandoff (takeHandoffFrame afterToken)
    if not (ByteString.null trailing)
        then Left (RelayMalformedMessage GrantRequestTag 2)
        else do
            relay <- fromHandoff (brokerRelayFromWire bindingBytes)
            token <- fromHandoff (handoffTokenFromBytes tokenFrame)
            offer <- fromHandoff (mkHandoffOffer relay payload token)
            challenge <- fromHandoff (handoffChallengeFromBytes challengeRaw)
            pure (offer, challenge)

-- ---------------------------------------------------------------------------
-- Channel plumbing

offerFieldsOf :: HandoffOffer scope brokerGeneration -> ByteString -> [ByteString]
offerFieldsOf offer keyDigest = [payload, token, binding, keyDigest]
  where
    (payload, token, binding) = handoffOfferFrames offer

offerWireOf :: HandoffOffer scope brokerGeneration -> ByteString
offerWireOf offer = frameWire payload <> frameWire token <> frameWire binding
  where
    (payload, token, binding) = handoffOfferFrames offer

transmit :: HandoffChannel -> ProtocolTag -> Word64 -> [ByteString] -> IO (Either RelayError ())
transmit channel tag request fields = case protocolMessage tag request fields of
    Left failure -> pure (Left (RelayProtocolFailure failure))
    Right message -> do
        sent <- channelSend channel message
        pure (either (Left . RelayProtocolFailure) Right sent)

receive :: HandoffChannel -> IO (Either RelayError ProtocolMessage)
receive channel = do
    received <- channelReceive channel
    pure (either (Left . RelayProtocolFailure) Right received)

-- | Receive the tag the exchange expects next, or report what arrived instead.
await :: HandoffChannel -> ProtocolTag -> IO (Either RelayError [ByteString])
await channel expected = do
    received <- receive channel
    pure $ case received of
        Left failure -> Left failure
        Right message
            | protocolMessageTag message == expected -> Right (protocolMessageFields message)
            | protocolMessageTag message == RefusedTag -> Left (refusalFrom message)
            | otherwise -> Left (RelayUnexpectedMessage (protocolMessageTag message))

-- | Tell the peer why this frame stopped, and keep the original cause.
refuse :: HandoffChannel -> Word64 -> RelayError -> IO (Either RelayError ())
refuse channel request failure = do
    _ <- transmit channel RefusedTag request [refusalCode failure, refusalDetail failure]
    pure (Left failure)

refusalFrom :: ProtocolMessage -> RelayError
refusalFrom message = case protocolMessageFields message of
    [code, detail] ->
        RelayRefusedByPeer
            (TextEncoding.decodeUtf8Lenient code)
            (TextEncoding.decodeUtf8Lenient detail)
    _ -> RelayRefusedByPeer "unspecified" ""

refusalCode :: RelayError -> ByteString
refusalCode failure = case failure of
    RelayProtocolFailure _ -> "protocol"
    RelayHandoffFailure _ -> "unauthenticated"
    RelayEdgeNotPlanned _ -> "edge-not-planned"
    RelayMalformedMessage _ _ -> "malformed-message"
    RelayUnexpectedMessage _ -> "unexpected-message"
    RelayRefusedByPeer _ _ -> "peer-refused"

refusalDetail :: RelayError -> ByteString
refusalDetail = TextEncoding.encodeUtf8 . Text.pack . relayErrorMessage

-- ---------------------------------------------------------------------------
-- Failures

-- | Every way a relayed exchange stops.
data RelayError
    = RelayProtocolFailure ProtocolError
    | RelayHandoffFailure HandoffError
    | -- | the root's plan names no such edge
      RelayEdgeNotPlanned Text
    | RelayMalformedMessage ProtocolTag Int
    | RelayUnexpectedMessage ProtocolTag
    | -- | the peer declined: code, then detail
      RelayRefusedByPeer Text Text
    deriving (Eq, Show)

-- | A one-line diagnostic.
relayErrorMessage :: RelayError -> String
relayErrorMessage failure = case failure of
    RelayProtocolFailure detail -> protocolErrorMessage detail
    RelayHandoffFailure detail -> handoffErrorMessage detail
    RelayEdgeNotPlanned reason -> "handoff relay: the plan names no such edge: " <> Text.unpack reason
    RelayMalformedMessage tag actual ->
        "handoff relay: " <> show tag <> " arrived with " <> show actual <> " fields"
    RelayUnexpectedMessage tag -> "handoff relay: unexpected " <> show tag
    RelayRefusedByPeer code detail ->
        "handoff relay: the peer refused (" <> Text.unpack code <> "): " <> Text.unpack detail

fromHandoff :: Either HandoffError a -> Either RelayError a
fromHandoff = either (Left . RelayHandoffFailure) Right

splitPair :: ByteString -> Either RelayError (ByteString, ByteString)
splitPair raw = do
    (first, rest) <- fromHandoff (takeHandoffFrame raw)
    (second, trailing) <- fromHandoff (takeHandoffFrame rest)
    if ByteString.null trailing
        then Right (first, second)
        else Left (RelayMalformedMessage OfferResponseTag 1)
