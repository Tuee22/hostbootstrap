module CoerceVerifiedHandoffScope where

import Data.Coerce (coerce)
import HostBootstrap.Handoff (VerifiedHandoff)

data ScopeA
data ScopeB
data Broker

wrongScope ::
    VerifiedHandoff ScopeA Broker ->
    VerifiedHandoff ScopeB Broker
wrongScope = coerce

