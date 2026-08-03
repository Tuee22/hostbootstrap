module CrossScopeHandoff where

import HostBootstrap.Config.Vocab (Harness, Production)
import HostBootstrap.Handoff

-- A Production broker cannot relay a binding minted by a Harness root, even
-- when both name the same project and broker-generation types.
crossScopeRelay ::
    RootBroker (Production projectId) brokerGeneration verb ->
    HandoffBinding (Harness projectId runId) brokerGeneration ->
    Either HandoffError (BrokerRelay (Production projectId) brokerGeneration)
crossScopeRelay broker binding = brokerRelay broker binding

-- Authenticated config evidence retains the same scope index through the
-- Config.Schema admission seam.
crossScopeConfig ::
    AuthenticatedConfigPayload (Harness projectId runId) brokerGeneration ->
    AuthenticatedConfigPayload (Production projectId) brokerGeneration
crossScopeConfig = id
