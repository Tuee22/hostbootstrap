module ProductionEvidenceAsHarnessProfile where

import HostBootstrap.Authority (AuthorityError, RootScopeAuthority)
import HostBootstrap.Config.Vocab (HarnessAuthority)
import HostBootstrap.Lifecycle.Mode
import HostBootstrap.ProjectScope (Harness, Production)

data Project
data Run
data BrokerGeneration

-- A Production root-scope witness cannot open the Harness profile, even when
-- every other argument belongs to one exact Harness run.
wrongScope ::
    RootScopeAuthority (Production Project) ->
    HarnessAuthority Project Run ->
    RunId Run ->
    ActiveProjectMode (Harness Project Run) BrokerGeneration ->
    UnboundRunLease (Harness Project Run) BrokerGeneration ->
    IO (Either AuthorityError ())
wrongScope root harness run active lease =
    withHarnessLifecycleProfile root harness run active lease (const ())
