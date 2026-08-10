module CoerceBrokerLinkScope where

import Data.Coerce (coerce)
import HostBootstrap.Handoff.Relay (BrokerLink)

data ScopeA
data ScopeB
data Broker

wrongScope ::
    BrokerLink ScopeA Broker ->
    BrokerLink ScopeB Broker
wrongScope = coerce

