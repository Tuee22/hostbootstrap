module CoerceBrokerLinkBroker where

import Data.Coerce (coerce)
import HostBootstrap.Handoff.Relay (BrokerLink)

data Scope
data BrokerA
data BrokerB

wrongBroker :: BrokerLink Scope BrokerA -> BrokerLink Scope BrokerB
wrongBroker = coerce
