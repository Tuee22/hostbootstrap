module CrossBackendProviderResult where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Reconcile

-- A call result indexed by backend B cannot settle a prepared backend-A call.
badSettle ::
  PreparedProviderStop
    scope
    planId
    backendA
    providerId
    operationKey
    callDigest
    attempt
    journalVersion ->
  ProviderStopCallResult
    scope
    planId
    backendB
    providerId
    operationKey
    callDigest
    attempt
    journalVersion ->
  Either
    ReconcileError
    (ProviderPhaseAdvance scope planId backendA providerId Stopped)
badSettle prepared result = settleProviderStop prepared result
