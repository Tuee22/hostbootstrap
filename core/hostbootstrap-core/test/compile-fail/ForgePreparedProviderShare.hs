module ForgePreparedProviderShare where

import HostBootstrap.Substrate.Provider.Reconcile

-- A backend cannot fabricate a share call without its sealed provider probe.
badCall ::
  PreparedProviderShare
    scope
    planId
    backendId
    providerId
    shareId
    operationKey
    callDigest
    attempt
    journalVersion
badCall = PreparedProviderShare
