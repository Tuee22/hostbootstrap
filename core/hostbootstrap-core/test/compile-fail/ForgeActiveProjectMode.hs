module ForgeActiveProjectMode where

import HostBootstrap.Lifecycle.Mode (ActiveProjectMode)
import HostBootstrap.ProjectScope (Production)

data Project
data BrokerGeneration

-- Only productionActiveMode and harnessActiveMode narrow a held indexed lease.
forgedActiveMode :: ActiveProjectMode (Production Project) BrokerGeneration
forgedActiveMode = ActiveProjectMode
