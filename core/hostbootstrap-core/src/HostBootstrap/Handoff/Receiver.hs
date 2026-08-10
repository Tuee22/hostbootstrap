{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The in-binary receiver: the child half of the authenticated handoff
exchange (§ X, § EE, the authenticated-handoff-and-child-admission phase).

A descending binary does not read its config from a file some wrapper wrote for
it. It runs this exchange on its own duplex channel and ends up holding a
'VerifiedHandoff' — or nothing at all:

@
parent                          child (this module)
  │   Offer(payload, token, binding, keyDigest)   ──▶  parse, check what it
  │                                                    independently knows
  │   ◀──  Challenge(fresh nonce)                      mint a fresh challenge
  │   Grant(signature, signerKeyDigest)           ──▶  verify against the
  │                                                    /installed/ key
  │   ◀──  Accepted(config digest)                     admit the exact bytes
  │   ◀──  Completed(status) | Refused(code, detail)
@

Three properties are worth stating because they are what a shell writer cannot
have. The challenge is minted *here*, after the offer arrives, so a transcript
recorded from an earlier descent carries a signature over a nonce this receiver
never issued. The verification key is a separate installed input; the offer's
key digest is compared against it and is never used as one, so an envelope that
certifies itself certifies nothing. And every refusal is *sent* before the
receiver returns, so a parent learns that its child declined rather than
inferring it from a closed pipe.

The message sequence is checked by 'ChildProtocolState' rather than by the
order of statements here, so a receiver cannot answer a grant it never asked
for.
-}
module HostBootstrap.Handoff.Receiver (
    -- * What a receiver independently expects
    ReceiverExpectation (..),

    -- * The received edge
    ReceivedEdge,
    receivedEdgeHandoff,
    receivedEdgeConfig,
    receivedEdgeBinding,

    -- * The exchange
    withReceivedHandoffEdge,

    -- * Failures
    ReceiverError (..),
    receiverErrorMessage,
) where

import Control.Exception.Safe (SomeException, throwIO, try)
import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Handoff (
    HandoffBinding,
    HandoffError,
    HandoffPayloadKind,
    HandoffScope,
    ProjectVerificationKey,
    authenticatedConfigDigest,
    challengeBytes,
    frameWire,
    freshChallenge,
    handoffErrorMessage,
    handoffGrantFromSignature,
    handoffInstalledProject,
    handoffPayloadKind,
    handoffScope,
    handoffScopeProject,
    handoffScopeTag,
    handoffVerb,
    verificationKeyDigest,
    verifiedConfigPayload,
    verifiedHandoffBinding,
    verifyHandoff,
    withHandoffBindingFromWire,
 )
import HostBootstrap.Handoff.Protocol (
    ChildProtocolState,
    HandoffChannel,
    ProtocolError,
    ProtocolMessage,
    ProtocolTag (AcceptedTag, ChallengeTag, CompletedTag, GrantTag, OfferTag, RefusedTag),
    channelReceive,
    channelSend,
    childProtocolReceive,
    childProtocolSend,
    initialChildProtocolState,
    protocolErrorMessage,
    protocolMessage,
    protocolMessageFields,
    protocolMessageRequestId,
    protocolMessageTag,
 )
import HostBootstrap.Handoff.Receiver.Internal (
    ReceivedEdge,
    mkReceivedEdge,
    receivedEdgeConfig,
    receivedEdgeHandoff,
 )

-- ---------------------------------------------------------------------------
-- What the receiver knows without a config

{- | The part of an edge a descending binary can state before it has received
anything.

It is deliberately small. A child cannot independently know the plan revision,
the broker generation, or the digest of a config it has not seen — those are
authenticated by the root's signature over the canonical binding, not by
guessing them. Installed project and scope are fixed by the opaque
'HandoffScope' passed separately; this record repeats them only as descriptive
process expectations and can narrow, never reindex, that evidence. It also
names the invoked verb and payload kind. Anything else is a wrong-edge refusal
before a signature is even considered.

The child frame is checked separately by @authorizeChildProject@, once the
config the binding names has actually been admitted.
-}
data ReceiverExpectation = ReceiverExpectation
    { receiverProject :: Text
    -- ^ a descriptive assertion narrowed by the opaque scope evidence
    , receiverScopeTag :: Text
    -- ^ a descriptive assertion narrowed by the opaque scope evidence
    , receiverVerb :: Text
    -- ^ the verb this binary was invoked as
    , receiverPayloadKind :: HandoffPayloadKind
    -- ^ the kind of payload this receiver is prepared to admit
    }
    deriving (Eq, Show)

-- | The authenticated binding this edge was signed for.
receivedEdgeBinding ::
    ReceivedEdge scope brokerGeneration ->
    HandoffBinding scope brokerGeneration
receivedEdgeBinding = verifiedHandoffBinding . receivedEdgeHandoff

-- ---------------------------------------------------------------------------
-- The exchange

{- | Run the child half of one handoff exchange, then act under it.

The continuation is rank-2 in the broker generation, while its scope is fixed
by the independently obtained 'HandoffScope'. An authenticated generation is
evidence about itself and cannot be laundered into another one; the received
config can now feed only the codec for that exact known scope.

A continuation that returns 'Left' declines the edge; the reason is sent to the
parent as a refusal and returned as 'ReceiverDeclined'. An exception it throws
is announced the same way and then re-thrown, so a parent never sees a child
that simply stopped talking.
-}
withReceivedHandoffEdge ::
    HandoffScope scope ->
    HandoffChannel ->
    -- | the independently installed verification key — never one the offer supplied
    ProjectVerificationKey ->
    ReceiverExpectation ->
    (forall receivedGeneration. ReceivedEdge scope receivedGeneration -> IO (Either Text result)) ->
    IO (Either ReceiverError result)
withReceivedHandoffEdge scope channel key expectation use = do
    active <- newIORef 0
    outcome <- runAttempt (exchange scope channel key expectation active use)
    case outcome of
        Right value -> pure (Right value)
        Left failure -> do
            announceRefusal channel active failure
            pure (Left failure)

exchange ::
    HandoffScope scope ->
    HandoffChannel ->
    ProjectVerificationKey ->
    ReceiverExpectation ->
    IORef Word64 ->
    (forall brokerGeneration. ReceivedEdge scope brokerGeneration -> IO (Either Text result)) ->
    Attempt result
exchange scope channel key expectation active use = do
    (offer, afterOffer) <- receiveMessage channel initialChildProtocolState
    liftAttempt (writeIORef active (protocolMessageRequestId offer))
    let requestId = protocolMessageRequestId offer
    (payload, token, bindingBytes, offeredKeyDigest) <- offerFields offer
    requireInstalledKey key offeredKeyDigest
    continued <-
        fromHandoff
            ( withHandoffBindingFromWire scope bindingBytes $ \binding ->
                exchangeBound
                    scope
                    channel
                    key
                    expectation
                    active
                    use
                    requestId
                    payload
                    token
                    bindingBytes
                    afterOffer
                    binding
            )
    continued

exchangeBound ::
    HandoffScope scope ->
    HandoffChannel ->
    ProjectVerificationKey ->
    ReceiverExpectation ->
    IORef Word64 ->
    (forall receivedGeneration. ReceivedEdge scope receivedGeneration -> IO (Either Text result)) ->
    Word64 ->
    ByteString ->
    ByteString ->
    ByteString ->
    ChildProtocolState ->
    HandoffBinding scope brokerGeneration ->
    Attempt result
exchangeBound scope channel key expectation active use requestId payload token bindingBytes afterOffer binding = do
    checkExpectation scope expectation binding
    challenge <- liftAttempt freshChallenge
    afterChallenge <-
        sendMessage channel afterOffer ChallengeTag requestId [challengeBytes challenge]
    (grantMessage, afterGrant) <- receiveMessage channel afterChallenge
    (signature, signerKeyDigest) <- grantFields grantMessage
    requireInstalledKey key signerKeyDigest
    verified <-
        fromHandoff
            ( verifyHandoff
                key
                (frameWire payload <> frameWire token <> frameWire bindingBytes)
                binding
                challenge
                (handoffGrantFromSignature signature)
            )
    admitted <- fromHandoff (verifiedConfigPayload verified)
    let edge = mkReceivedEdge verified admitted channel requestId
    afterAccepted <-
        sendMessage
            channel
            afterGrant
            AcceptedTag
            requestId
            [TextEncoding.encodeUtf8 (authenticatedConfigDigest admitted)]
    used <- liftAttempt (try (use edge))
    case used of
        Left (failure :: SomeException) -> do
            -- Announce before re-throwing: the parent is entitled to know the
            -- child accepted the edge and then failed under it, which is a
            -- different thing from the child never having accepted it.
            liftAttempt (announceRefusal channel active (ReceiverCrashed (firstLine (show failure))))
            liftAttempt (throwIO failure)
        Right (Left reason) -> failAttempt (ReceiverDeclined reason)
        Right (Right value) -> do
            _ <- sendMessage channel afterAccepted CompletedTag requestId ["ok"]
            pure value

-- ---------------------------------------------------------------------------
-- Message shapes

offerFields :: ProtocolMessage -> Attempt (ByteString, ByteString, ByteString, ByteString)
offerFields message = case protocolMessageFields message of
    [payload, token, binding, keyDigest] -> pure (payload, token, binding, keyDigest)
    fields -> failAttempt (ReceiverMalformedMessage OfferTag (length fields))

grantFields :: ProtocolMessage -> Attempt (ByteString, ByteString)
grantFields message = case protocolMessageFields message of
    [signature, keyDigest] -> pure (signature, keyDigest)
    fields -> failAttempt (ReceiverMalformedMessage GrantTag (length fields))

{- | Compare the digest the peer named against the digest of the key this
binary has installed.

This is a fast, legible refusal for the ordinary operational mistake — a child
image carrying last generation's installed key. It is never a key *source*: the
signature is checked against 'ProjectVerificationKey' regardless of what the
message said.
-}
requireInstalledKey :: ProjectVerificationKey -> ByteString -> Attempt ()
requireInstalledKey key offered
    | TextEncoding.encodeUtf8 (verificationKeyDigest key) == offered = pure ()
    | otherwise = failAttempt ReceiverKeyMismatch

{- | Refuse an edge that does not describe this binary, before any signature
work.
-}
checkExpectation ::
    HandoffScope scope ->
    ReceiverExpectation ->
    HandoffBinding scope brokerGeneration ->
    Attempt ()
checkExpectation scope expectation binding = do
    require
        (handoffInstalledProject binding == handoffScopeProject scope)
        ("the offered edge names project " <> handoffInstalledProject binding)
    require
        (handoffScope binding == handoffScopeTag scope)
        ("the offered edge names scope " <> handoffScope binding)
    require
        (handoffInstalledProject binding == receiverProject expectation)
        ("the offered edge names project " <> handoffInstalledProject binding)
    require
        (handoffScope binding == receiverScopeTag expectation)
        ("the offered edge names scope " <> handoffScope binding)
    require
        (handoffVerb binding == receiverVerb expectation)
        ("the offered edge authorizes " <> handoffVerb binding)
    require
        (handoffPayloadKind binding == receiverPayloadKind expectation)
        (Text.pack ("the offered payload is " <> show (handoffPayloadKind binding)))
  where
    require True _ = pure ()
    require False detail = failAttempt (ReceiverWrongEdge detail)

-- ---------------------------------------------------------------------------
-- Sequenced transport

{- | Receive one message and advance the child's protocol state.

An explicit refusal from the parent is reported as such rather than as an
invalid transition, because "the parent declined" and "the parent is speaking a
protocol this receiver does not know" are different operational facts.
-}
receiveMessage :: HandoffChannel -> ChildProtocolState -> Attempt (ProtocolMessage, ChildProtocolState)
receiveMessage channel state = do
    received <- liftAttempt (channelReceive channel)
    message <- either (failAttempt . ReceiverProtocolFailure) pure received
    next <- either (failAttempt . ReceiverProtocolFailure) pure (childProtocolReceive state message)
    case protocolMessageTag message of
        RefusedTag -> failAttempt (refusalFrom message)
        _ -> pure (message, next)

refusalFrom :: ProtocolMessage -> ReceiverError
refusalFrom message = case protocolMessageFields message of
    [code, detail] -> ReceiverRefusedByParent (lossyText code) (lossyText detail)
    _ -> ReceiverRefusedByParent "unspecified" ""

-- | Build, validate, send, and advance the child's protocol state.
sendMessage ::
    HandoffChannel ->
    ChildProtocolState ->
    ProtocolTag ->
    Word64 ->
    [ByteString] ->
    Attempt ChildProtocolState
sendMessage channel state tag requestId fields = do
    message <- either (failAttempt . ReceiverProtocolFailure) pure (protocolMessage tag requestId fields)
    next <- either (failAttempt . ReceiverProtocolFailure) pure (childProtocolSend state message)
    sent <- liftAttempt (channelSend channel message)
    either (failAttempt . ReceiverProtocolFailure) pure sent
    pure next

{- | Tell the parent why this receiver stopped.

Best effort by construction: the channel may already be gone, and a failure to
report a failure must not replace it. A refusal before the offer arrived has no
request id to answer, so there is nothing well-formed to send.
-}
announceRefusal :: HandoffChannel -> IORef Word64 -> ReceiverError -> IO ()
announceRefusal channel active failure = do
    requestId <- readIORef active
    case (requestId, failure) of
        (0, _) -> pure ()
        -- A refusal received from the parent is not echoed back at it.
        (_, ReceiverRefusedByParent _ _) -> pure ()
        _ -> case protocolMessage RefusedTag requestId [refusalCode failure, refusalDetail failure] of
            Left _ -> pure ()
            Right message -> do
                _ <- channelSend channel message
                pure ()

refusalCode :: ReceiverError -> ByteString
refusalCode failure = case failure of
    ReceiverProtocolFailure _ -> "protocol"
    ReceiverHandoffFailure _ -> "unauthenticated"
    ReceiverKeyMismatch -> "installed-key-mismatch"
    ReceiverWrongEdge _ -> "wrong-edge"
    ReceiverMalformedMessage _ _ -> "malformed-message"
    ReceiverRefusedByParent _ _ -> "parent-refused"
    ReceiverDeclined _ -> "child-declined"
    ReceiverCrashed _ -> "child-failed"

refusalDetail :: ReceiverError -> ByteString
refusalDetail = TextEncoding.encodeUtf8 . Text.pack . receiverErrorMessage

-- ---------------------------------------------------------------------------
-- Failures

{- | Every way a receiver stops.

No constructor carries the one-time token, the challenge, the signature bytes,
or the config payload; the digests a binding already publishes are the most
identifying thing a diagnostic contains.
-}
data ReceiverError
    = ReceiverProtocolFailure ProtocolError
    | ReceiverHandoffFailure HandoffError
    | -- | the offer names a key other than the one this binary installed
      ReceiverKeyMismatch
    | -- | the edge does not describe this binary
      ReceiverWrongEdge Text
    | -- | the tag arrived with a field count its shape does not have
      ReceiverMalformedMessage ProtocolTag Int
    | -- | the parent declined: code, then detail
      ReceiverRefusedByParent Text Text
    | -- | this binary declined the edge it authenticated
      ReceiverDeclined Text
    | -- | this binary failed under an edge it had accepted
      ReceiverCrashed Text
    deriving (Eq, Show)

-- | A one-line diagnostic.
receiverErrorMessage :: ReceiverError -> String
receiverErrorMessage failure = case failure of
    ReceiverProtocolFailure detail -> protocolErrorMessage detail
    ReceiverHandoffFailure detail -> handoffErrorMessage detail
    ReceiverKeyMismatch ->
        "handoff receiver: the offer names a project key other than the installed one"
    ReceiverWrongEdge detail -> "handoff receiver: " <> Text.unpack detail
    ReceiverMalformedMessage tag actual ->
        "handoff receiver: " <> show tag <> " arrived with " <> show actual <> " fields"
    ReceiverRefusedByParent code detail ->
        "handoff receiver: the parent refused (" <> Text.unpack code <> "): " <> Text.unpack detail
    ReceiverDeclined reason -> "handoff receiver: declined the edge: " <> Text.unpack reason
    ReceiverCrashed detail ->
        "handoff receiver: failed under the accepted edge: " <> Text.unpack detail

-- ---------------------------------------------------------------------------
-- A short-circuiting exchange

{- | The exchange is a sequence in which any step can refuse, so it is written
as one. The alternative — nesting a @case@ per message — buries the protocol
order under its error handling, which is the part a reader most needs to see.
-}
newtype Attempt a = Attempt {runAttempt :: IO (Either ReceiverError a)}

instance Functor Attempt where
    fmap f (Attempt action) = Attempt (fmap (fmap f) action)

instance Applicative Attempt where
    pure = Attempt . pure . Right
    Attempt f <*> Attempt x =
        Attempt $ do
            function <- f
            case function of
                Left failure -> pure (Left failure)
                Right g -> fmap (fmap g) x

instance Monad Attempt where
    Attempt action >>= f =
        Attempt $ do
            outcome <- action
            case outcome of
                Left failure -> pure (Left failure)
                Right value -> runAttempt (f value)

liftAttempt :: IO a -> Attempt a
liftAttempt = Attempt . fmap Right

failAttempt :: ReceiverError -> Attempt a
failAttempt = Attempt . pure . Left

fromHandoff :: Either HandoffError a -> Attempt a
fromHandoff = either (failAttempt . ReceiverHandoffFailure) pure

lossyText :: ByteString -> Text
lossyText = TextEncoding.decodeUtf8Lenient

firstLine :: String -> Text
firstLine = Text.pack . takeWhile (/= '\n')
