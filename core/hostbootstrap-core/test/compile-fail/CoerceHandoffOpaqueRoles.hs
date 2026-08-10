module CoerceHandoffOpaqueRoles where

import Data.Coerce (coerce)
import HostBootstrap.Handoff
import HostBootstrap.Handoff.Receiver (ReceivedEdge)

data HandoffScopeA
data HandoffScopeB

wrongHandoffScope :: HandoffScope HandoffScopeA -> HandoffScope HandoffScopeB
wrongHandoffScope = coerce

data BindingScopeA
data BindingScopeB
data BindingBrokerA
data BindingBrokerB

wrongBindingScope :: HandoffBinding BindingScopeA BindingBrokerA -> HandoffBinding BindingScopeB BindingBrokerA
wrongBindingScope = coerce

wrongBindingBroker :: HandoffBinding BindingScopeA BindingBrokerA -> HandoffBinding BindingScopeA BindingBrokerB
wrongBindingBroker = coerce

data RootScopeA
data RootScopeB
data RootBrokerA
data RootBrokerB
data RootVerbA
data RootVerbB

wrongRootScope :: RootBroker RootScopeA RootBrokerA RootVerbA -> RootBroker RootScopeB RootBrokerA RootVerbA
wrongRootScope = coerce

wrongRootBroker :: RootBroker RootScopeA RootBrokerA RootVerbA -> RootBroker RootScopeA RootBrokerB RootVerbA
wrongRootBroker = coerce

wrongRootVerb :: RootBroker RootScopeA RootBrokerA RootVerbA -> RootBroker RootScopeA RootBrokerA RootVerbB
wrongRootVerb = coerce

data RouteScopeA
data RouteScopeB
data RouteBrokerA
data RouteBrokerB

wrongRouteScope :: BrokerRoute RouteScopeA RouteBrokerA -> BrokerRoute RouteScopeB RouteBrokerA
wrongRouteScope = coerce

wrongRouteBroker :: BrokerRoute RouteScopeA RouteBrokerA -> BrokerRoute RouteScopeA RouteBrokerB
wrongRouteBroker = coerce

data RelayScopeA
data RelayScopeB
data RelayBrokerA
data RelayBrokerB

wrongRelayScope :: BrokerRelay RelayScopeA RelayBrokerA -> BrokerRelay RelayScopeB RelayBrokerA
wrongRelayScope = coerce

wrongRelayBroker :: BrokerRelay RelayScopeA RelayBrokerA -> BrokerRelay RelayScopeA RelayBrokerB
wrongRelayBroker = coerce

data OfferScopeA
data OfferScopeB
data OfferBrokerA
data OfferBrokerB

wrongOfferScope :: HandoffOffer OfferScopeA OfferBrokerA -> HandoffOffer OfferScopeB OfferBrokerA
wrongOfferScope = coerce

wrongOfferBroker :: HandoffOffer OfferScopeA OfferBrokerA -> HandoffOffer OfferScopeA OfferBrokerB
wrongOfferBroker = coerce

data PayloadScopeA
data PayloadScopeB
data PayloadBrokerA
data PayloadBrokerB

wrongPayloadScope :: AuthenticatedConfigPayload PayloadScopeA PayloadBrokerA -> AuthenticatedConfigPayload PayloadScopeB PayloadBrokerA
wrongPayloadScope = coerce

wrongPayloadBroker :: AuthenticatedConfigPayload PayloadScopeA PayloadBrokerA -> AuthenticatedConfigPayload PayloadScopeA PayloadBrokerB
wrongPayloadBroker = coerce

data ReceivedScopeA
data ReceivedScopeB
data ReceivedBrokerA
data ReceivedBrokerB

wrongReceivedScope :: ReceivedEdge ReceivedScopeA ReceivedBrokerA -> ReceivedEdge ReceivedScopeB ReceivedBrokerA
wrongReceivedScope = coerce

wrongReceivedBroker :: ReceivedEdge ReceivedScopeA ReceivedBrokerA -> ReceivedEdge ReceivedScopeA ReceivedBrokerB
wrongReceivedBroker = coerce
