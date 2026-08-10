module CrossBackendProviderCall where

import HostBootstrap.Substrate.Provider.Backend
import HostBootstrap.Substrate.Provider.Reconcile

-- A call prepared for backend A cannot execute through backend B.
badRun ::
  StrongProviderBackend backendB ->
  PreparedProviderStop
    scope
    planId
    backendA
    providerId
    operationKey
    callDigest
    attempt
    journalVersion ->
  IO
    ( ProviderStopCallResult
        scope
        planId
        backendA
        providerId
        operationKey
        callDigest
        attempt
        journalVersion
    )
badRun backend prepared = runProviderStopCall backend prepared
