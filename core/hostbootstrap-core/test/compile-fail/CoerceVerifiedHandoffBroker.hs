module CoerceVerifiedHandoffBroker where

import Data.Coerce (coerce)
import HostBootstrap.Handoff (VerifiedHandoff)

data Scope
data BrokerA
data BrokerB

wrongBroker :: VerifiedHandoff Scope BrokerA -> VerifiedHandoff Scope BrokerB
wrongBroker = coerce
