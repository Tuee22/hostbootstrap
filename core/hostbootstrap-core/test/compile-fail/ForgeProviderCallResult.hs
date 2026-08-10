module ForgeProviderCallResult where

import HostBootstrap.Substrate.Provider.Reconcile

-- Only a clause-holding backend can bind a raw report to a prepared call.
badResult ::
  ProviderProvisionCallResult
    scope
    planId
    backendId
    providerId
    operationKey
    callDigest
    attempt
    journalVersion
badResult = ProviderProvisionCallResult
