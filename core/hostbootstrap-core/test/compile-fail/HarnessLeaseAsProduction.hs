module HarnessLeaseAsProduction where

import HostBootstrap.Authority (AuthorityError, RootScopeAuthority)
import HostBootstrap.Lifecycle.Mode
import HostBootstrap.ProjectScope (Harness, Production)

data Project
data Run
data BrokerGeneration

openProduction ::
    RootScopeAuthority (Production Project) ->
    ActiveProjectMode (Production Project) BrokerGeneration ->
    UnboundRunLease (Production Project) BrokerGeneration ->
    IO (Either AuthorityError ())
openProduction root active lease =
    withProductionLifecycleProfile root active lease (const ())

-- A Harness root, active mode, and unbound lease cannot open the Production
-- profile. The mismatch is structural, before any protected slot is consumed.
productionFromHarness ::
    RootScopeAuthority (Harness Project Run) ->
    ActiveProjectMode (Harness Project Run) BrokerGeneration ->
    UnboundRunLease (Harness Project Run) BrokerGeneration ->
    IO (Either AuthorityError ())
productionFromHarness root active lease =
    openProduction root active lease
