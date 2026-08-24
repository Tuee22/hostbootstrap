{-# LANGUAGE GADTs #-}
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
  │   Offer(payload, token, binding, scope/key/evidence)
  │                                           ──▶ verify scope capsule first
  │   ◀──  Challenge(fresh nonce)                      mint inside that scope
  │   Grant(signature, signerKeyDigest)           ──▶  verify against the
  │                                                    /installed/ key
  │   ◀──  Accepted(payload digest)                    classify signed kind,
  │                                                    verify exact evidence
  │   ◀──  Completed(status) | Refused(code, detail)
@

Four properties are worth stating because they are what a shell writer cannot
have. The root-signed scope capsule is verified before the binding or payload is
interpreted, so received bytes cannot choose a Production or Harness phantom.
The challenge is minted *here*, inside that scope after the offer arrives, so a
transcript recorded from an earlier descent carries a signature over a nonce
this receiver never issued. The verification key is a separate installed
input; the offer's key digest is compared against it and is never used as one,
so an envelope that certifies itself certifies nothing. And every refusal is
*sent* before the receiver returns, so a parent learns that its child declined
rather than inferring it from a closed pipe.

The message sequence is checked by 'ChildProtocolState' rather than by the
order of statements here, so a receiver cannot answer a grant it never asked
for.
-}
module HostBootstrap.Handoff.Receiver (
    -- * Closed authenticated branches
    ReceivedEdge,
    ReceivedRecoveryDescent,

    -- * The exchange
    withIsolatedReceivedHandoffEdge,
    withReceivedHandoffEdge,
    withProviderDependencyClientKernel,

    -- * Failures
    ReceiverError (..),
    receiverErrorMessage,
) where

import Control.Concurrent.MVar (modifyMVar, modifyMVarMasked, newMVar)
import qualified Control.Exception as Exception
import Control.Exception.Safe (SomeException, throwIO, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority (
    InstalledProjectIdentity,
    ProjectVerb (ProjectDestroy, ProjectDown, ProjectUp),
 )
import HostBootstrap.Config.Vocab (Harness, Production)
import HostBootstrap.Handoff (
    AuthenticatedConfigPayload,
    AuthenticatedRootScope,
    HandoffBinding,
    HandoffError (HandoffBindingMismatch, HandoffWireTrailingBytes),
    HandoffPayloadKind (NarrowedProjectConfig, RecoveryAdapterWire),
    HandoffScope,
    ProjectVerificationKey,
    VerifiedHandoff,
    authenticatedConfigDigest,
    challengeBytes,
    frameWire,
    freshChallenge,
    handoffChildConfigDigest,
    handoffChildFrame,
    handoffErrorMessage,
    handoffGrantFromSignature,
    handoffInstalledProject,
    handoffParentFrame,
    handoffPayloadKind,
    handoffPhase,
    handoffPlanRevision,
    handoffScope,
    handoffScopeProject,
    handoffScopeTag,
    handoffVerb,
    mkRecoveryProjectionBindingFromRoute,
    providerDependencyPackagesFromFields,
    providerDependencyProbeRequestFields,
    providerDependencyProbeResponseFromFields,
    recoveryWireGrantFromSignature,
    renderRecoveryProjectionBinding,
    takeHandoffFrame,
    verificationKeyDigest,
    verifiedConfigPayload,
    verifiedHandoffBinding,
    verifiedHandoffRoute,
    verifyHandoff,
    withAuthenticatedRootScopeFromWire,
    withHandoffBindingFromWire,
    withRecoveryProjectionBindingInput,
    withVerifiedRecoveryChildPackage,
    withVerifiedRecoveryWire,
    withVerifiedRootedPayloadBinding,
 )
import HostBootstrap.Handoff.Protocol (
    ChildProtocolState,
    HandoffChannel,
    ProtocolError,
    ProtocolMessage,
    ProtocolTag (AcceptedTag, AcknowledgedTag, ChallengeTag, CompletedTag, GrantTag, OfferTag, ProviderDependencyPackageTag, ProviderDependencyProbeRequestTag, ProviderDependencyProbeResponseTag, RefusedTag),
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
    withPrivateProtocolStdio,
 )
import HostBootstrap.Handoff.Receiver.Internal (
    ReceivedEdge,
    ReceivedRecoveryDescent,
    mkReceivedEdge,
    mkReceivedRecoveryDescent,
    receivedEdgeChannel,
    receivedEdgeRequestId,
 )

-- ---------------------------------------------------------------------------
-- The exchange

{- | Run the dedicated child exchange on descriptors nothing else can reach.

A child launched for a recursive lifecycle is handed one duplex channel and it
is the process's own standard input and output. That is a workable transport
and an unworkable ambient environment: the very descriptors the root's frames
travel on are also the ones an ordinary @getLine@ reads from and an ordinary
@putStrLn@ writes to. A single diagnostic line printed by a configuration
decoder, a plan projection, or a lifecycle effect is not a cosmetic problem —
it is a byte in the middle of a length-framed protocol message.

So the receiver takes the descriptors before anything else can, through
'withPrivateProtocolStdio' — the one owner of that isolation, shared with every
other end of this channel, because a second copy of a descriptor bracket is a
second chance to get the ordering wrong. Nothing here inspects, chooses, or
accepts a descriptor: the entry takes no channel and no handle, so there is no
argument through which a caller supplies one and no seam through which a test
substitutes one.
-}
withIsolatedReceivedHandoffEdge ::
    InstalledProjectIdentity projectId ->
    -- | the independently installed verification key — never one the offer supplied
    ProjectVerificationKey ->
    ( forall receivedGeneration.
      ReceivedEdge (Production projectId) receivedGeneration ->
      AuthenticatedConfigPayload (Production projectId) receivedGeneration ->
      (ByteString -> IO (Either ReceiverError ())) ->
      IO (Either Text ())
    ) ->
    ( forall receivedGeneration planDigest parentFrame childFrame recoveryWireDigest recoveryWireId verb.
      ReceivedRecoveryDescent
        (Production projectId)
        receivedGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb ->
      (ByteString -> IO (Either ReceiverError ())) ->
      IO (Either Text ())
    ) ->
    ( forall runId receivedGeneration.
      ReceivedEdge (Harness projectId runId) receivedGeneration ->
      AuthenticatedConfigPayload (Harness projectId runId) receivedGeneration ->
      (ByteString -> IO (Either ReceiverError ())) ->
      IO (Either Text ())
    ) ->
    ( forall runId receivedGeneration planDigest parentFrame childFrame recoveryWireDigest recoveryWireId verb.
      ReceivedRecoveryDescent
        (Harness projectId runId)
        receivedGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb ->
      (ByteString -> IO (Either ReceiverError ())) ->
      IO (Either Text ())
    ) ->
    IO (Either ReceiverError ())
withIsolatedReceivedHandoffEdge
    project
    key
    useProductionConfig
    useProductionRecovery
    useHarnessConfig
    useHarnessRecovery =
        withPrivateProtocolStdio $ \channel ->
            withReceivedHandoffEdge
                project
                channel
                key
                useProductionConfig
                useProductionRecovery
                useHarnessConfig
                useHarnessRecovery

{- | Run the child half of one handoff exchange, then act under it.

The independently installed project identity and key verify the leading scope
capsule before one of four closed continuations becomes reachable. Production
remains indexed by the installed @projectId@; each Harness continuation is
rank-2 in a fresh @runId@ introduced by the verified capsule. Every continuation
is also rank-2 in the authenticated broker generation. Config and recovery
evidence are classified only after the ordinary grant succeeds, and the fixed
unit result leaves no ordinary evidence-return channel.

A continuation that returns 'Left' declines the edge; the reason is sent to the
parent as a refusal and returned as 'ReceiverDeclined'. An exception it throws
is announced the same way and then re-thrown, so a parent never sees a child
that simply stopped talking.
-}
withReceivedHandoffEdge ::
    InstalledProjectIdentity projectId ->
    HandoffChannel ->
    -- | the independently installed verification key — never one the offer supplied
    ProjectVerificationKey ->
    ( forall receivedGeneration.
      ReceivedEdge (Production projectId) receivedGeneration ->
      AuthenticatedConfigPayload (Production projectId) receivedGeneration ->
      (ByteString -> IO (Either ReceiverError ())) ->
      IO (Either Text ())
    ) ->
    ( forall receivedGeneration planDigest parentFrame childFrame recoveryWireDigest recoveryWireId verb.
      ReceivedRecoveryDescent
        (Production projectId)
        receivedGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb ->
      (ByteString -> IO (Either ReceiverError ())) ->
      IO (Either Text ())
    ) ->
    ( forall runId receivedGeneration.
      ReceivedEdge (Harness projectId runId) receivedGeneration ->
      AuthenticatedConfigPayload (Harness projectId runId) receivedGeneration ->
      (ByteString -> IO (Either ReceiverError ())) ->
      IO (Either Text ())
    ) ->
    ( forall runId receivedGeneration planDigest parentFrame childFrame recoveryWireDigest recoveryWireId verb.
      ReceivedRecoveryDescent
        (Harness projectId runId)
        receivedGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb ->
      (ByteString -> IO (Either ReceiverError ())) ->
      IO (Either Text ())
    ) ->
    IO (Either ReceiverError ())
withReceivedHandoffEdge
    project
    channel
    key
    useProductionConfig
    useProductionRecovery
    useHarnessConfig
    useHarnessRecovery = do
        active <- newIORef 0
        let attempt = do
                (offer, afterOffer) <- receiveMessage channel initialChildProtocolState
                liftAttempt (writeIORef active (protocolMessageRequestId offer))
                let requestId = protocolMessageRequestId offer
                (payload, token, bindingBytes, authentication) <- offerFields offer
                (scopeWire, authenticationRemainder) <-
                    fromHandoff (takeHandoffFrame authentication)
                scoped <-
                    fromHandoff
                        ( withAuthenticatedRootScopeFromWire
                            project
                            key
                            scopeWire
                            ( \authenticated scope ->
                                receiveScopedHandoffEdge
                                    authenticated
                                    scope
                                    channel
                                    key
                                    afterOffer
                                    requestId
                                    active
                                    payload
                                    token
                                    bindingBytes
                                    authenticationRemainder
                                    useProductionConfig
                                    useProductionRecovery
                            )
                            ( \authenticated scope ->
                                receiveScopedHandoffEdge
                                    authenticated
                                    scope
                                    channel
                                    key
                                    afterOffer
                                    requestId
                                    active
                                    payload
                                    token
                                    bindingBytes
                                    authenticationRemainder
                                    useHarnessConfig
                                    useHarnessRecovery
                            )
                        )
                scoped
        outcome <- runAttempt attempt
        case outcome of
            Right value -> pure (Right value)
            Left failure -> do
                announceRefusal channel active failure
                pure (Left failure)

{- | Open the hidden child client only for the lifetime of an authenticated
edge. It permits one in-flight request, consumes each nonce before sending,
and accepts one exact response carrying the edge's request identity.
-}
withProviderDependencyClientKernel ::
    ReceivedEdge scope brokerGeneration ->
    (Maybe [ByteString] -> (ByteString -> Text -> IO (Either ReceiverError (Either Text Word64))) -> IO (Either ReceiverError result)) ->
    IO (Either ReceiverError result)
withProviderDependencyClientKernel edge use = do
    case protocolMessage ProviderDependencyPackageTag requestId [ByteString.empty] of
        Left failure -> pure (Left (ReceiverProtocolFailure failure))
        Right requestMessage -> do
            sent <- channelSend channel requestMessage
            case sent of
                Left failure -> pure (Left (ReceiverProtocolFailure failure))
                Right () -> receivePackage
  where
    channel = receivedEdgeChannel edge
    requestId = receivedEdgeRequestId edge
    receivePackage = do
        announced <- channelReceive channel
        case announced of
            Left failure -> pure (Left (ReceiverProtocolFailure failure))
            Right message
                | protocolMessageRequestId message /= requestId ->
                    pure (Left (ReceiverWrongEdge "the provider dependency package has another request identity"))
                | protocolMessageTag message /= ProviderDependencyPackageTag ->
                    pure (Left (ReceiverMalformedMessage (protocolMessageTag message) (length (protocolMessageFields message))))
                | protocolMessageFields message == [ByteString.empty] ->
                    use Nothing (\_ _ -> pure (Left (ReceiverDeclined "no provider dependency package is admitted")))
                | otherwise -> case providerDependencyPackagesFromFields (protocolMessageFields message) of
                    Left failure -> pure (Left (ReceiverDeclined failure))
                    Right packageWires -> do
                        state <- newMVar (False, [])
                        use (Just packageWires) (probe packageWires state)
    probe packageWires state packageWire nonce
        | packageWire `notElem` packageWires = pure (Left (ReceiverDeclined "the provider dependency package is not admitted"))
        | otherwise = do
            admitted <- modifyMVar state $ \current@(busy, consumed) ->
                if busy
                    then pure (current, Left (ReceiverDeclined "a provider dependency request is already outstanding"))
                    else
                        if (packageWire, nonce) `elem` consumed
                            then pure (current, Left (ReceiverDeclined "the provider dependency nonce was replayed"))
                            else
                                if length consumed >= providerClientRequestLimit
                                    then pure (current, Left (ReceiverDeclined "the provider dependency client request limit was reached"))
                                    else pure ((True, (packageWire, nonce) : consumed), Right ())
            case admitted of
                Left failure -> pure (Left failure)
                Right () -> Exception.finally (exchange packageWire nonce) (modifyMVar state (\(_, consumed) -> pure ((False, consumed), ())))
    exchange packageWire nonce = case providerDependencyProbeRequestFields packageWire nonce of
        Left failure -> pure (Left (ReceiverDeclined failure))
        Right fields -> case protocolMessage ProviderDependencyProbeRequestTag requestId fields of
            Left failure -> pure (Left (ReceiverProtocolFailure failure))
            Right message -> do
                sent <- channelSend channel message
                case sent of
                    Left failure -> pure (Left (ReceiverProtocolFailure failure))
                    Right () -> do
                        answer <- channelReceive channel
                        case answer of
                            Left failure -> pure (Left (ReceiverProtocolFailure failure))
                            Right response
                                | protocolMessageRequestId response /= requestId ->
                                    pure (Left (ReceiverWrongEdge "the provider dependency response has another request identity"))
                                | protocolMessageTag response /= ProviderDependencyProbeResponseTag ->
                                    pure (Left (ReceiverMalformedMessage (protocolMessageTag response) (length (protocolMessageFields response))))
                                | otherwise ->
                                    pure $
                                        either
                                            (Left . ReceiverDeclined)
                                            Right
                                            (providerDependencyProbeResponseFromFields packageWire nonce (protocolMessageFields response))

providerClientRequestLimit :: Int
providerClientRequestLimit = 64

-- | Continue only after the capsule verifier has fixed the execution scope.
receiveScopedHandoffEdge ::
    AuthenticatedRootScope scope ->
    HandoffScope scope ->
    HandoffChannel ->
    ProjectVerificationKey ->
    ChildProtocolState ->
    Word64 ->
    IORef Word64 ->
    ByteString ->
    ByteString ->
    ByteString ->
    ByteString ->
    ( forall receivedGeneration.
      ReceivedEdge scope receivedGeneration ->
      AuthenticatedConfigPayload scope receivedGeneration ->
      (ByteString -> IO (Either ReceiverError ())) ->
      IO (Either Text ())
    ) ->
    ( forall receivedGeneration planDigest parentFrame childFrame recoveryWireDigest recoveryWireId verb.
      ReceivedRecoveryDescent
        scope
        receivedGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb ->
      (ByteString -> IO (Either ReceiverError ())) ->
      IO (Either Text ())
    ) ->
    Attempt ()
receiveScopedHandoffEdge
    authenticated
    scope
    channel
    key
    afterOffer
    requestId
    active
    payload
    token
    bindingBytes
    authentication
    useConfig
    useRecovery = do
        requireOfferPayloadBound payload
        (offeredKeyDigest, evidence) <- fromHandoff (takeHandoffFrame authentication)
        requireInstalledKey key offeredKeyDigest
        bound <-
            fromHandoff
                ( withHandoffBindingFromWire scope bindingBytes $ \binding -> do
                    checkScope scope binding
                    challenge <- liftAttempt freshChallenge
                    afterChallenge <-
                        sendMessage
                            channel
                            afterOffer
                            ChallengeTag
                            requestId
                            [challengeBytes challenge]
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
                    (acceptedDigest, branch) <-
                        classifyVerified
                            authenticated
                            channel
                            requestId
                            key
                            evidence
                            verified
                            useConfig
                            useRecovery
                    afterAccepted <-
                        sendMessage
                            channel
                            afterGrant
                            AcceptedTag
                            requestId
                            [TextEncoding.encodeUtf8 acceptedDigest]
                    used <-
                        liftAttempt
                            (try (runTerminalAction channel afterAccepted requestId active branch))
                    case used of
                        Left (failure :: SomeException) -> do
                            liftAttempt
                                ( announceRefusal
                                    channel
                                    active
                                    (ReceiverCrashed (firstLine (show failure)))
                                )
                            liftAttempt (throwIO failure)
                        Right (Left failure) -> failAttempt failure
                        Right (Right ()) -> pure ()
                )
        bound

runTerminalAction ::
    HandoffChannel ->
    ChildProtocolState ->
    Word64 ->
    IORef Word64 ->
    ((ByteString -> IO (Either ReceiverError ())) -> IO (Either Text ())) ->
    IO (Either ReceiverError ())
runTerminalAction channel state requestId active useTerminal = Exception.mask $ \restore -> do
    sendState <- newMVar (False, False, False)
    let sendReport report = do
            sent <- modifyMVarMasked sendState $ \current@(closed, attempted, _) ->
                if closed
                    then
                        pure
                            ( current
                            , Right (Left (ReceiverDeclined "the terminal report sender is closed"))
                            )
                    else
                        if attempted
                            then
                                pure
                                    ( current
                                    , Right
                                        (Left (ReceiverDeclined "the terminal report sender was already used"))
                                    )
                            else do
                                attemptedSend <-
                                    Exception.try
                                        ( runAttempt $ do
                                            awaiting <- sendMessage channel state CompletedTag requestId [report]
                                            (acknowledged, _finished) <- receiveMessage channel awaiting
                                            if protocolMessageTag acknowledged == AcknowledgedTag
                                                then pure ()
                                                else failAttempt (ReceiverDeclined "the parent did not acknowledge the terminal report")
                                        )
                                case attemptedSend of
                                    Left (failure :: SomeException) ->
                                        pure ((False, True, False), Left failure)
                                    Right outcome -> do
                                        case outcome of
                                            Right _ -> writeIORef active 0
                                            Left _ -> pure ()
                                        pure
                                            ( (False, True, either (const False) (const True) outcome)
                                            , Right (() <$ outcome)
                                            )
            case sent of
                Left failure -> throwIO failure
                Right outcome -> pure outcome
    used <- Exception.try (restore (useTerminal sendReport))
    delivered <-
        Exception.uninterruptibleMask_
            ( modifyMVar sendState $ \(_, attempted, completed) ->
                pure ((True, attempted, completed), completed)
            )
    case used of
        Left (failure :: SomeException) -> throwIO failure
        Right (Left reason) -> pure (Left (ReceiverDeclined reason))
        Right (Right ())
            | delivered -> pure (Right ())
            | otherwise ->
                pure
                    ( Left
                        (ReceiverDeclined "the terminal action returned without one successful report send")
                    )

-- ---------------------------------------------------------------------------
-- Message shapes

offerFields :: ProtocolMessage -> Attempt (ByteString, ByteString, ByteString, ByteString)
offerFields message = case protocolMessageFields message of
    [payload, token, binding, authentication] ->
        pure (payload, token, binding, authentication)
    fields -> failAttempt (ReceiverMalformedMessage OfferTag (length fields))

maxEmbeddedOfferPayloadBytes :: Int
maxEmbeddedOfferPayloadBytes = 7 * 1024 * 1024

requireOfferPayloadBound :: ByteString -> Attempt ()
requireOfferPayloadBound payload
    | ByteString.length payload <= maxEmbeddedOfferPayloadBytes = pure ()
    | otherwise =
        failAttempt
            (ReceiverWrongEdge "the embedded Offer payload exceeds its strict sub-ceiling")

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

-- | Narrow only the independently installed scope before signature work.
checkScope ::
    HandoffScope scope ->
    HandoffBinding scope brokerGeneration ->
    Attempt ()
checkScope scope binding = do
    require
        (handoffInstalledProject binding == handoffScopeProject scope)
        ("the offered edge names project " <> handoffInstalledProject binding)
    require
        (handoffScope binding == handoffScopeTag scope)
        ("the offered edge names scope " <> handoffScope binding)
  where
    require True _ = pure ()
    require False detail = failAttempt (ReceiverWrongEdge detail)

{- | Classify only after the ordinary one-use edge is authenticated.

The returned action is deliberately not run here. The caller first advances
the protocol through 'AcceptedTag'; only then can either callback observe its
joint branch evidence.
-}
classifyVerified ::
    AuthenticatedRootScope scope ->
    HandoffChannel ->
    Word64 ->
    ProjectVerificationKey ->
    ByteString ->
    VerifiedHandoff scope brokerGeneration ->
    ( ReceivedEdge scope brokerGeneration ->
      AuthenticatedConfigPayload scope brokerGeneration ->
      (ByteString -> IO (Either ReceiverError ())) ->
      IO (Either Text ())
    ) ->
    ( forall planDigest parentFrame childFrame recoveryWireDigest recoveryWireId verb.
      ReceivedRecoveryDescent
        scope
        brokerGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb ->
      (ByteString -> IO (Either ReceiverError ())) ->
      IO (Either Text ())
    ) ->
    Attempt (Text, (ByteString -> IO (Either ReceiverError ())) -> IO (Either Text ()))
classifyVerified authenticated channel requestId key evidence verified useConfig useRecovery =
    case handoffPayloadKind binding of
        NarrowedProjectConfig -> do
            rootedBytes <- configEvidence evidence
            _ <- fromHandoff (withVerifiedRootedPayloadBinding verified rootedBytes id)
            admitted <- fromHandoff (verifiedConfigPayload verified)
            pure
                ( authenticatedConfigDigest admitted
                , \sendReport -> do
                    let edge = mkReceivedEdge authenticated verified channel requestId
                    useConfig edge admitted sendReport
                )
        RecoveryAdapterWire ->
            case (handoffVerb binding, handoffPhase binding) of
                ("down", "teardown") ->
                    classifyRecovery ProjectDown
                ("destroy", "teardown") ->
                    classifyRecovery ProjectDestroy
                ("up", "teardown") ->
                    classifyRecovery ProjectUp
                (_, phase) ->
                    failAttempt
                        ( ReceiverWrongEdge
                            ("a recovery adapter must authorize teardown, received " <> phase)
                        )
  where
    binding = verifiedHandoffBinding verified

    classifyRecovery ::
        ProjectVerb verb ->
        Attempt (Text, (ByteString -> IO (Either ReceiverError ())) -> IO (Either Text ()))
    classifyRecovery verb = do
        (rootedBytes, projectionBytes, signature) <- recoveryEvidence evidence
        rooted <- fromHandoff (withVerifiedRootedPayloadBinding verified rootedBytes id)
        (package, adapter) <-
            fromHandoff
                ( withVerifiedRecoveryChildPackage verified rooted $ \package _childConfig adapter ->
                    (package, adapter)
                )
        inputAction <-
            fromHandoff
                ( withRecoveryProjectionBindingInput
                    (handoffPlanRevision binding)
                    (handoffParentFrame binding)
                    (handoffChildFrame binding)
                    ( \input ->
                        case mkRecoveryProjectionBindingFromRoute
                            verb
                            (verifiedHandoffRoute verified)
                            input
                            adapter
                            ( \projection ->
                                if renderRecoveryProjectionBinding projection /= projectionBytes
                                    then
                                        Left
                                            ( HandoffBindingMismatch
                                                "the recovery evidence projection is not canonical for the authenticated adapter"
                                            )
                                    else do
                                        grant <- recoveryWireGrantFromSignature projection signature
                                        withVerifiedRecoveryWire
                                            key
                                            projection
                                            adapter
                                            grant
                                            ( \wire sendReport -> do
                                                let edge =
                                                        mkReceivedEdge
                                                            authenticated
                                                            verified
                                                            channel
                                                            requestId
                                                    descent =
                                                        mkReceivedRecoveryDescent
                                                            edge
                                                            rooted
                                                            package
                                                            verb
                                                            projection
                                                            grant
                                                            wire
                                                useRecovery descent sendReport
                                            )
                            ) of
                            Left failure -> failAttempt (ReceiverHandoffFailure failure)
                            Right result -> fromHandoff result
                    )
                )
        action <- inputAction
        pure (handoffChildConfigDigest binding, action)

configEvidence :: ByteString -> Attempt ByteString
configEvidence evidence = do
    (rooted, trailing) <- fromHandoff (takeHandoffFrame evidence)
    if ByteString.null trailing
        then pure rooted
        else
            failAttempt
                (ReceiverHandoffFailure (HandoffWireTrailingBytes (ByteString.length trailing)))

recoveryEvidence :: ByteString -> Attempt (ByteString, ByteString, ByteString)
recoveryEvidence evidence = do
    (rooted, afterRooted) <- fromHandoff (takeHandoffFrame evidence)
    (projection, afterProjection) <- fromHandoff (takeHandoffFrame afterRooted)
    (signature, trailing) <- fromHandoff (takeHandoffFrame afterProjection)
    if ByteString.null trailing
        then pure (rooted, projection, signature)
        else
            failAttempt
                ( ReceiverHandoffFailure
                    (HandoffWireTrailingBytes (ByteString.length trailing))
                )

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
