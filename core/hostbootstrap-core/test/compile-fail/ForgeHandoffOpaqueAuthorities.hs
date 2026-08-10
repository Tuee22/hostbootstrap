module ForgeHandoffOpaqueAuthorities where

import HostBootstrap.Handoff
import HostBootstrap.Handoff.Receiver
import HostBootstrap.Handoff.Relay

data Scope
data Broker
data Verb

forgedScope :: HandoffScope Scope
forgedScope = ProductionHandoffScope undefined

forgedBinding :: HandoffBinding Scope Broker
forgedBinding = HandoffBinding

forgedRootBroker :: RootBroker Scope Broker Verb
forgedRootBroker = RootBroker

forgedRoute :: BrokerRoute Scope Broker
forgedRoute = BrokerRoute

forgedRelay :: BrokerRelay Scope Broker
forgedRelay = BrokerRelay

forgedOffer :: HandoffOffer Scope Broker
forgedOffer = HandoffOffer

forgedPayload :: AuthenticatedConfigPayload Scope Broker
forgedPayload = AuthenticatedConfigPayload

forgedReceived :: ReceivedEdge Scope Broker
forgedReceived = ReceivedEdge

forgedLink :: BrokerLink Scope Broker
forgedLink = BrokerLink

forgedVerified :: VerifiedHandoff Scope Broker
forgedVerified = VerifiedHandoff
