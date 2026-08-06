module RelaySignsWithoutBroker where

import HostBootstrap.Handoff
import HostBootstrap.Handoff.Relay

-- A relayed link is a channel and a request identity. It is not a broker, and
-- there is no function that turns one into the other: an intermediate frame
-- relays, and only the root signs.
signFromRelayedLink ::
    HandoffChannel ->
    ProjectVerificationKey ->
    HandoffOffer scope brokerGeneration ->
    HandoffChallenge ->
    IO (Either HandoffError (HandoffGrant scope brokerGeneration))
signFromRelayedLink channel key =
    grantHandoff (relayedBrokerLink channel 1 key)
