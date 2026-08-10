module CoerceActivationBrokerRoles where

import Data.Coerce (coerce)
import HostBootstrap.Activation (ActivationBroker)

data ScopeA
data ScopeB
data BrokerA
data BrokerB
data VerbA
data VerbB

wrongScope ::
    ActivationBroker ScopeA BrokerA VerbA ->
    ActivationBroker ScopeB BrokerA VerbA
wrongScope = coerce

wrongBroker ::
    ActivationBroker ScopeA BrokerA VerbA ->
    ActivationBroker ScopeA BrokerB VerbA
wrongBroker = coerce

wrongVerb ::
    ActivationBroker ScopeA BrokerA VerbA ->
    ActivationBroker ScopeA BrokerA VerbB
wrongVerb = coerce
