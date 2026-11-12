module CarryCreatedRestartedProvider where

import Data.Text (Text)
import HostBootstrap.Lifecycle.Execution (StepExecution)
import HostBootstrap.Reconcile (Provisioned, ReconcileError, Running, Stopped)
import HostBootstrap.Substrate.Provider.Reconcile

-- A newly provisioned origin is admitted.
created ::
    StepExecution scope planId ->
    ProviderPhaseAdvance scope planId backendId providerId Provisioned Running ->
    Text ->
    IO (Either ReconcileError ())
created = carryCreatedRunningProviderSettlement

-- A restart cannot claim the acquisition's absent predecessor.
restarted ::
    StepExecution scope planId ->
    ProviderPhaseAdvance scope planId backendId providerId Stopped Running ->
    Text ->
    IO (Either ReconcileError ())
restarted execution advance adapter =
    carryCreatedRunningProviderSettlement execution advance adapter
