module HarnessLeaseAsProduction where

import HostBootstrap.Config.Vocab (Harness)
import HostBootstrap.Lifecycle.Mode

-- A harness run's lease cannot open the Production profile: the scope index on
-- the lease is the whole point, so a test component has no route to Production.
harnessLease :: UnboundRunLease (Harness projectId runId) brokerGeneration
harnessLease = undefined

modeLease :: ProjectModeLease projectId brokerGeneration
modeLease = undefined

productionFromHarness :: Either ModeError (LifecycleProfile (Harness projectId runId))
productionFromHarness = withProductionLifecycleProfile modeLease harnessLease
