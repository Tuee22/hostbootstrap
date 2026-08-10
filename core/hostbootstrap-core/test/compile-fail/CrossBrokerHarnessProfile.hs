module CrossBrokerHarnessProfile where

import HostBootstrap.Authority (AuthorityError, RootScopeAuthority)
import HostBootstrap.Config.Vocab (HarnessAuthority)
import HostBootstrap.Lifecycle.Mode
import HostBootstrap.ProjectScope (Harness)

data Project
data Run
data BrokerA
data BrokerB

-- Harness profile admission cannot combine an active mode from one broker
-- generation with another generation's unbound lease.
wrongBroker ::
    RootScopeAuthority (Harness Project Run) ->
    HarnessAuthority Project Run ->
    RunId Run ->
    ActiveProjectMode (Harness Project Run) BrokerA ->
    UnboundRunLease (Harness Project Run) BrokerB ->
    IO (Either AuthorityError ())
wrongBroker root harness run active lease =
    withHarnessLifecycleProfile root harness run active lease (const ())
