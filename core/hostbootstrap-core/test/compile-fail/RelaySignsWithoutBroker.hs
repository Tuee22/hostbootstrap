module RelaySignsWithoutBroker where

import HostBootstrap.Handoff
import HostBootstrap.Handoff.Receiver (ReceivedEdge)
import HostBootstrap.Handoff.Relay

-- A relayed link comes only from an already verified received edge. It is not
-- a broker, and there is no function that turns one into the other: an
-- intermediate frame relays, and only the root signs.
signFromRelayedLink ::
    ReceivedEdge scope brokerGeneration ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    IO (Either HandoffError (HandoffGrant scope brokerGeneration))
signFromRelayedLink edge =
    grantHandoff (relayedBrokerLink edge)
