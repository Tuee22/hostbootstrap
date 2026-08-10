module CrossBrokerProductionProfile where

import HostBootstrap.Authority (AuthorityError, RootScopeAuthority)
import HostBootstrap.Lifecycle.Mode
import HostBootstrap.ProjectScope (Production)

data Project
data BrokerA
data BrokerB

-- The active mode and the unbound lease must come from the same protected
-- broker generation.
wrongBroker ::
    RootScopeAuthority (Production Project) ->
    ActiveProjectMode (Production Project) BrokerA ->
    UnboundRunLease (Production Project) BrokerB ->
    IO (Either AuthorityError ())
wrongBroker root active lease =
    withProductionLifecycleProfile root active lease (const ())
