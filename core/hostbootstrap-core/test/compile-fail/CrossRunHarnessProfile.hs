module CrossRunHarnessProfile where

import HostBootstrap.Authority (AuthorityError, RootScopeAuthority)
import HostBootstrap.Config.Vocab (HarnessAuthority)
import HostBootstrap.Lifecycle.Mode
import HostBootstrap.ProjectScope (Harness)

data Project
data RunA
data RunB
data BrokerGeneration

-- Root, Harness authority, and run witness name RunA; the active mode and lease
-- for RunB cannot complete that evidence tuple.
wrongRun ::
    RootScopeAuthority (Harness Project RunA) ->
    HarnessAuthority Project RunA ->
    RunId RunA ->
    ActiveProjectMode (Harness Project RunB) BrokerGeneration ->
    UnboundRunLease (Harness Project RunB) BrokerGeneration ->
    IO (Either AuthorityError ())
wrongRun root harness run active lease =
    withHarnessLifecycleProfile root harness run active lease (const ())
