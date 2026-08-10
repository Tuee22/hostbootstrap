module CrossScopeBrokerRelay where

import HostBootstrap.Config.Vocab (Harness, Production)
import HostBootstrap.Handoff

crossScopeRelay ::
    RootBroker (Production projectId) brokerGeneration verb ->
    HandoffBinding (Harness projectId runId) brokerGeneration ->
    Either HandoffError (BrokerRelay (Production projectId) brokerGeneration)
crossScopeRelay broker binding = brokerRelay broker binding
