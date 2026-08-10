module CrossScopeAuthenticatedConfig where

import HostBootstrap.Config.Vocab (Harness, Production)
import HostBootstrap.Handoff (AuthenticatedConfigPayload)

crossScopeConfig ::
    AuthenticatedConfigPayload (Harness projectId runId) brokerGeneration ->
    AuthenticatedConfigPayload (Production projectId) brokerGeneration
crossScopeConfig = id
