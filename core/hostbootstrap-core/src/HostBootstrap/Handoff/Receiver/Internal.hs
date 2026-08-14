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
    mkReceivedEdge,
    mkReceivedRecoveryDescent,
    withReceivedRecoveryDescent,
    rootedLifecycleRequestPathKernel,
    rootedLifecycleResponsePairPathKernel,
) where

import Data.ByteString (ByteString)
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
import HostBootstrap.Handoff.Protocol (HandoffChannel)
import qualified HostBootstrap.Handoff.Rooted as Rooted

data ReceivedEdge scope (brokerGeneration :: Type) = ReceivedEdge
    { receivedRootScope :: AuthenticatedRootScope scope
    , receivedHandoff :: VerifiedHandoff scope brokerGeneration
    , receivedChannel :: HandoffChannel
    , receivedRequest :: Word64
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

mkReceivedEdge ::
    AuthenticatedRootScope scope ->
    VerifiedHandoff scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ReceivedEdge scope brokerGeneration
mkReceivedEdge = ReceivedEdge

{- | One exact recovery-kind edge joined to its independently verified adapter.

The constructor and all retained evidence stay in this Cabal-private module.
Besides the joint proofs, the carrier keeps the closed verb term and typed
package/projection/grant/wire values later lifecycle and completion kernels need.
The receiver is the sole producer; later code consumes the opaque package
rather than pairing an edge with recovery evidence of its choosing.
-}
data ReceivedRecoveryDescent
    scope brokerGeneration planDigest parentFrame childFrame
    recoveryWireDigest recoveryWireId verb where
    ReceivedRecoveryDescent ::
        ReceivedEdge scope brokerGeneration ->
        RootedPayloadBinding scope brokerGeneration ->
        RecoveryChildPackage ->
        ProjectVerb verb ->
        RecoveryProjectionBinding
            scope brokerGeneration verb planDigest parentFrame childFrame recoveryWireDigest ->
        RecoveryWireGrant
            scope brokerGeneration verb planDigest parentFrame childFrame recoveryWireDigest ->
        VerifiedRecoveryWire
            scope brokerGeneration verb planDigest childFrame recoveryWireDigest recoveryWireId ->
        ReceivedRecoveryDescent
            scope brokerGeneration planDigest parentFrame childFrame
            recoveryWireDigest recoveryWireId verb

type role ReceivedRecoveryDescent nominal nominal nominal nominal nominal nominal nominal nominal

mkReceivedRecoveryDescent ::
    ReceivedEdge scope brokerGeneration ->
    RootedPayloadBinding scope brokerGeneration ->
    RecoveryChildPackage ->
    ProjectVerb verb ->
    RecoveryProjectionBinding
        scope brokerGeneration verb planDigest parentFrame childFrame recoveryWireDigest ->
    RecoveryWireGrant
        scope brokerGeneration verb planDigest parentFrame childFrame recoveryWireDigest ->
    VerifiedRecoveryWire
        scope brokerGeneration verb planDigest childFrame recoveryWireDigest recoveryWireId ->
    ReceivedRecoveryDescent
        scope brokerGeneration planDigest parentFrame childFrame
        recoveryWireDigest recoveryWireId verb
mkReceivedRecoveryDescent = ReceivedRecoveryDescent

withReceivedRecoveryDescent ::
    ReceivedRecoveryDescent
        scope brokerGeneration planDigest parentFrame childFrame
        recoveryWireDigest recoveryWireId verb ->
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
        edge
            `seq` rooted
            `seq` package
            `seq` verb
            `seq` projection
            `seq` grant
            `seq` wire
            `seq` use
                edge
                (renderRecoveryChildPackage package)
                verb
                (verifiedRecoveryWireBytes wire)
                (renderRecoveryProjectionBinding projection)
                (recoveryWireGrantSignature grant)

-- | Strictly decode one exact request and expose only its requester path.
-- 'OpenFrame' deliberately has no inner ancestry; its sealed relay envelope
-- is therefore the sole path used by the root endpoint.
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

-- | Strictly decode and pair one response, returning only its echoed path.
-- Neither value nor any lifecycle field escapes this neutral transport fold.
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
