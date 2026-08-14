module ForgeHandoffOpaqueAuthorities where

import HostBootstrap.Handoff

data Scope
data Broker
data Verb

forgedScope :: HandoffScope Scope
forgedScope = ProductionHandoffScope undefined

forgedBinding :: HandoffBinding Scope Broker
forgedBinding = HandoffBinding

forgedRootedBinding :: RootedPayloadBinding Scope Broker
forgedRootedBinding = RootedPayloadBinding

forgedRecoveryPackage :: RecoveryChildPackage
forgedRecoveryPackage = RecoveryChildPackage

forgedAuthenticatedRootScope :: AuthenticatedRootScope Scope
forgedAuthenticatedRootScope = AuthenticatedRootScope

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

forgedVerified :: VerifiedHandoff Scope Broker
forgedVerified = VerifiedHandoff
