module ReadReceivedEdgeTransport where

-- Public received edges expose only verified handoff/config evidence. Their
-- raw channel and request identity remain package-private so ordinary callers
-- must derive a BrokerLink, whose requester-path framing is sealed.
import HostBootstrap.Handoff.Receiver
    ( receivedEdgeChannel
    , receivedEdgeRequestId
    )
