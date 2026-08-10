module ForeignProviderStop where

import HostBootstrap.Lifecycle.Execution (StepExecution)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.ProjectPlan (PlannedResource)
import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Reconcile

-- An observed foreign provider is not plan-owned stop authority.
badStop ::
  StepExecution scope planId ->
  PlannedResource scope planId providerId ProviderResource providerFrame ->
  ResourceHandle scope planId providerId ProviderResource Unmanaged Observed ->
  PreparedGate ->
  Either ReconcileError ()
badStop execution planned handle gate =
  withPreparedProviderStop execution planned handle gate (const ())
