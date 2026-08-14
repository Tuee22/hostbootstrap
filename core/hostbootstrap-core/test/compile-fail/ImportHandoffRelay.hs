module ImportHandoffRelay where

import HostBootstrap.Handoff.Relay
    ( BrokerLink
    , adoptLifecycleAcknowledgementThroughLink
    , prepareLifecycleAcknowledgementThroughLink
    , withReceivedLifecycleAcknowledgementKernel
    , withReceivedRecoveryLifecycleAcknowledgementKernel
    )

hidden :: BrokerLink scope broker -> ()
hidden _ = ()
