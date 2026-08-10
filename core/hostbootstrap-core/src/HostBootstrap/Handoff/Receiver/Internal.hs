{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Package-private carrier for the relay endpoint of a verified edge.
module HostBootstrap.Handoff.Receiver.Internal (
    ReceivedEdge,
    receivedEdgeHandoff,
    receivedEdgeConfig,
    receivedEdgeChannel,
    receivedEdgeRequestId,
    mkReceivedEdge,
) where

import Data.Kind (Type)
import Data.Word (Word64)
import HostBootstrap.Handoff (
    AuthenticatedConfigPayload,
    VerifiedHandoff,
 )
import HostBootstrap.Handoff.Protocol (HandoffChannel)

data ReceivedEdge scope (brokerGeneration :: Type) = ReceivedEdge
    { receivedHandoff :: VerifiedHandoff scope brokerGeneration
    , receivedConfig :: AuthenticatedConfigPayload scope brokerGeneration
    , receivedChannel :: HandoffChannel
    , receivedRequest :: Word64
    }

type role ReceivedEdge nominal nominal

instance Show (ReceivedEdge scope brokerGeneration) where
    show edge = "ReceivedEdge " <> show (receivedHandoff edge)

receivedEdgeHandoff ::
    ReceivedEdge scope brokerGeneration ->
    VerifiedHandoff scope brokerGeneration
receivedEdgeHandoff = receivedHandoff

receivedEdgeConfig ::
    ReceivedEdge scope brokerGeneration ->
    AuthenticatedConfigPayload scope brokerGeneration
receivedEdgeConfig = receivedConfig

receivedEdgeChannel :: ReceivedEdge scope brokerGeneration -> HandoffChannel
receivedEdgeChannel = receivedChannel

receivedEdgeRequestId :: ReceivedEdge scope brokerGeneration -> Word64
receivedEdgeRequestId = receivedRequest

mkReceivedEdge ::
    VerifiedHandoff scope brokerGeneration ->
    AuthenticatedConfigPayload scope brokerGeneration ->
    HandoffChannel ->
    Word64 ->
    ReceivedEdge scope brokerGeneration
mkReceivedEdge = ReceivedEdge
