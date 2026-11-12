{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Package-private carrier for the relay endpoint of a verified edge.
module HostBootstrap.Handoff.Receiver.Internal (
    ReceivedEdge,
    ReceivedRecoveryDescent,
    receivedEdgeAuthenticatedRootScope,
    receivedEdgeHandoff,
    receivedEdgeChannel,
    receivedEdgeRequestId,
    receivedEdgeProgressOpen,
    stopReceivedEdgeAnnouncement,
    mkReceivedEdge,
    mkReceivedRecoveryDescent,
    withReceivedRecoveryDescent,
    rootedLifecycleRequestPathKernel,
    rootedLifecycleResponsePairPathKernel,
) where

import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', readIORef)
import Data.Kind (Type)
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Authority (ProjectVerb)
import HostBootstrap.Handoff (
    AuthenticatedRootScope,
    RecoveryChildPackage,
    RecoveryProjectionBinding,
    RecoveryWireGrant,
    RootedPayloadBinding,
    VerifiedHandoff,
    VerifiedRecoveryWire,
    childConfigDigest,
    recoveryWireGrantSignature,
    renderRecoveryChildPackage,
    renderRecoveryProjectionBinding,
    verifiedRecoveryWireBytes,
 )
import HostBootstrap.Handoff.Protocol (ChildProtocolState, HandoffChannel)
import qualified HostBootstrap.Handoff.Rooted as Rooted

data ReceivedEdge scope (brokerGeneration :: Type) = ReceivedEdge
    { receivedRootScope :: AuthenticatedRootScope scope
    , receivedHandoff :: VerifiedHandoff scope brokerGeneration
    , receivedChannel :: HandoffChannel
    , receivedRequest :: Word64
    , receivedProgress :: IORef (Word64, Maybe ChildProtocolState)
    }

type role ReceivedEdge nominal nominal

receivedEdgeAuthenticatedRootScope ::
    ReceivedEdge scope brokerGeneration ->
    AuthenticatedRootScope scope
receivedEdgeAuthenticatedRootScope = receivedRootScope

receivedEdgeHandoff ::
    ReceivedEdge scope brokerGeneration ->
    VerifiedHandoff scope brokerGeneration
receivedEdgeHandoff = receivedHandoff

receivedEdgeChannel :: ReceivedEdge scope brokerGeneration -> HandoffChannel
receivedEdgeChannel = receivedChannel

receivedEdgeRequestId :: ReceivedEdge scope brokerGeneration -> Word64
receivedEdgeRequestId = receivedRequest

-- | Whether this admitted edge still has an open upstream exchange.
receivedEdgeProgressOpen :: ReceivedEdge scope brokerGeneration -> IO Bool
receivedEdgeProgressOpen edge =
    maybe False (const True) . snd <$> readIORef (receivedProgress edge)

-- | A consumed parent refusal leaves no child refusal to announce later.
stopReceivedEdgeAnnouncement :: ReceivedEdge scope brokerGeneration -> IO ()
stopReceivedEdgeAnnouncement edge =
    atomicModifyIORef' (receivedProgress edge) (\(request, _) -> ((request, Nothing), ()))

mkReceivedEdge ::
    AuthenticatedRootScope scope ->
    VerifiedHandoff scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    IORef (Word64, Maybe ChildProtocolState) ->
    ReceivedEdge scope brokerGeneration
mkReceivedEdge = ReceivedEdge

{- | One exact recovery-kind edge joined to its independently verified adapter.

The constructor and all retained evidence stay in this Cabal-private module.
Besides the joint proofs, the carrier keeps the closed verb term and typed
package/projection/grant/wire values. Its sole eliminator,
'withReceivedRecoveryDescent', passes six arguments: the received edge, rendered
package, closed verb, authenticated adapter bytes, rendered projection and grant
signature. It forces the retained rooted binding without exposing it; package,
adapter, projection and grant typing ends at that byte boundary. The receiver
is the sole producer.
-}
data
    ReceivedRecoveryDescent
        scope
        brokerGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb
    where
    ReceivedRecoveryDescent ::
        ReceivedEdge scope brokerGeneration ->
        RootedPayloadBinding scope brokerGeneration ->
        RecoveryChildPackage ->
        ProjectVerb verb ->
        RecoveryProjectionBinding
            scope
            brokerGeneration
            verb
            planDigest
            parentFrame
            childFrame
            recoveryWireDigest ->
        RecoveryWireGrant
            scope
            brokerGeneration
            verb
            planDigest
            parentFrame
            childFrame
            recoveryWireDigest ->
        VerifiedRecoveryWire
            scope
            brokerGeneration
            verb
            planDigest
            childFrame
            recoveryWireDigest
            recoveryWireId ->
        ReceivedRecoveryDescent
            scope
            brokerGeneration
            planDigest
            parentFrame
            childFrame
            recoveryWireDigest
            recoveryWireId
            verb

type role ReceivedRecoveryDescent nominal nominal nominal nominal nominal nominal nominal nominal

mkReceivedRecoveryDescent ::
    ReceivedEdge scope brokerGeneration ->
    RootedPayloadBinding scope brokerGeneration ->
    RecoveryChildPackage ->
    ProjectVerb verb ->
    RecoveryProjectionBinding
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    RecoveryWireGrant
        scope
        brokerGeneration
        verb
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest ->
    VerifiedRecoveryWire
        scope
        brokerGeneration
        verb
        planDigest
        childFrame
        recoveryWireDigest
        recoveryWireId ->
    ReceivedRecoveryDescent
        scope
        brokerGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb
mkReceivedRecoveryDescent = ReceivedRecoveryDescent

withReceivedRecoveryDescent ::
    ReceivedRecoveryDescent
        scope
        brokerGeneration
        planDigest
        parentFrame
        childFrame
        recoveryWireDigest
        recoveryWireId
        verb ->
    ( ReceivedEdge scope brokerGeneration ->
      ByteString ->
      ProjectVerb verb ->
      ByteString ->
      ByteString ->
      ByteString ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withReceivedRecoveryDescent
    (ReceivedRecoveryDescent edge rooted package verb projection grant wire)
    use =
        edge `seq`
            rooted `seq`
                package `seq`
                    verb `seq`
                        projection `seq`
                            grant `seq`
                                wire `seq`
                                    use
                                        edge
                                        (renderRecoveryChildPackage package)
                                        verb
                                        (verifiedRecoveryWireBytes wire)
                                        (renderRecoveryProjectionBinding projection)
                                        (recoveryWireGrantSignature grant)

{- | Strictly decode one exact request and expose only its requester path.
'OpenFrame' deliberately has no inner ancestry; its sealed relay envelope
is therefore the sole path used by the root endpoint.
-}
rootedLifecycleRequestPathKernel :: ByteString -> Either Text (Maybe [Text])
rootedLifecycleRequestPathKernel raw = do
    request <- Rooted.rootedLifecycleRequestFromWireKernel raw
    pure
        ( Rooted.withRootedLifecycleRequestKernel
            request
            (const Nothing)
            path
            bodyPath
            bodyPath
            path
            path
        )
  where
    path value _ _ _ _ _ = Just value
    bodyPath value _ _ _ _ _ _ = Just value

{- | Strictly decode and pair one response, returning only its echoed path.
Neither value nor any lifecycle field escapes this neutral transport fold.
-}
rootedLifecycleResponsePairPathKernel ::
    ByteString ->
    ByteString ->
    Either Text [Text]
rootedLifecycleResponsePairPathKernel exactRequest signedResponse = do
    request <- Rooted.rootedLifecycleRequestFromWireKernel exactRequest
    response <- Rooted.rootedLifecycleResponseFromWireKernel signedResponse
    _ <-
        Rooted.rootedLifecycleResponsePairKernel
            (childConfigDigest exactRequest)
            request
            response
    pure
        ( Rooted.withRootedLifecycleResponseKernel
            response
            opened
            prepared
            post
            post
            post
            textPost
            textPost
        )
  where
    opened _ value _ _ _ _ = value
    prepared _ value _ _ _ _ _ _ _ _ _ = value
    post _ value _ _ _ _ _ _ = value
    textPost _ value _ _ _ _ _ _ = value
