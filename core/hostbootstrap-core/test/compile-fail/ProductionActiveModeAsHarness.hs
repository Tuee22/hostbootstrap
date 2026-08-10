module ProductionActiveModeAsHarness where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (ActiveProjectMode)
import HostBootstrap.ProjectScope (Harness, Production)

data Project
data Run
data BrokerGeneration

-- Production and Harness active-mode authorities have nominally distinct
-- scopes and cannot substitute for one another.
wrongScope ::
    ActiveProjectMode (Production Project) BrokerGeneration ->
    ActiveProjectMode (Harness Project Run) BrokerGeneration
wrongScope = coerce
