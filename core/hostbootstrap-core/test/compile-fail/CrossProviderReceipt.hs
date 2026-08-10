module CrossProviderReceipt where

import HostBootstrap.Lifecycle.Execution (StepExecution)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.ProjectPlan (PlannedResource)
import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Reconcile

-- A wrapper for provider B cannot authorize a stop of provider A.
badStop ::
  StepExecution scope planId ->
  PlannedResource scope planId providerA ProviderResource providerFrame ->
  ManagedProviderHandle scope planId backendId providerB Running ->
  PreparedGate ->
  Either ReconcileError ()
badStop execution planned managedProviderB gate =
  withPreparedProviderStop execution planned managedProviderB gate (const ())
