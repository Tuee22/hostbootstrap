module CrossRunActiveProjectMode where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (ActiveProjectMode)
import HostBootstrap.ProjectScope (Harness)

data Project
data RunA
data RunB
data BrokerGeneration

-- An active Harness mode cannot be relabelled to a second run.
wrongRun ::
    ActiveProjectMode (Harness Project RunA) BrokerGeneration ->
    ActiveProjectMode (Harness Project RunB) BrokerGeneration
wrongRun = coerce
