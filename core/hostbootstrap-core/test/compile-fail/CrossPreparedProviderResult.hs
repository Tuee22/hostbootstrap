module CrossPreparedProviderResult where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Reconcile

-- A result minted by prepared call B cannot settle prepared call A, even for
-- the same provider and backend.
badSettle ::
  PreparedProviderStop
    scope
    planId
    backendId
    providerId
    operationA
    callDigestA
    attemptA
    journalVersionA ->
  ProviderStopCallResult
    scope
    planId
    backendId
    providerId
    operationB
    callDigestB
    attemptB
    journalVersionB ->
  Either
    ReconcileError
    (ProviderPhaseAdvance scope planId backendId providerId Stopped)
badSettle prepared result = settleProviderStop prepared result
