module HandoffFormerProtocolReexport where

import HostBootstrap.Handoff
    ( BrokerLink
    , ChildProtocolState
    , ProtocolError
    , ProtocolMessage
    , ProtocolTag
    , adoptLifecycleAcknowledgementThroughLink
    , prepareLifecycleAcknowledgementThroughLink
    , protocolMessage
    , withReceivedLifecycleAcknowledgementKernel
    , withReceivedRecoveryLifecycleAcknowledgementKernel
    )

former :: ()
former = ()
