module ForgePreparedProviderProvision where

import HostBootstrap.Substrate.Provider.Reconcile

-- Prepared provider calls can only be minted from an exact planned execution.
badCall ::
  PreparedProviderProvision
    scope
    planId
    backendId
    providerId
    operationKey
    callDigest
    attempt
    journalVersion
badCall = PreparedProviderProvision
