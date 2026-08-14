{- | The journal-bound provider-start package is abstract; a caller cannot
manufacture it before an owning backend result exists. -}
module ForgePreparedProviderStart where

import HostBootstrap.Reconcile (PreparedProviderStart)

forged ::
  PreparedProviderStart
    scope
    planId
    providerResourceId
    operationKey
    callDigest
    attempt
    journalVersion
forged = PreparedProviderStart
