module ImportHandoffRelay where

import HostBootstrap.Handoff.Relay (
    BrokerLink,
    adoptLifecycleAcknowledgementThroughLink,
    prepareLifecycleAcknowledgementThroughLink,
 )

hidden :: BrokerLink scope broker -> ()
hidden _ = ()
