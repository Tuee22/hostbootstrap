module ForgeManagedProviderHandles where

import HostBootstrap.Reconcile
import HostBootstrap.Substrate.Provider.Reconcile

-- Generic lifecycle values cannot forge either backend-indexed provider
-- authority wrapper: both constructors are package-private.
badProvider ::
  ManagedProviderHandle scope planId backendId providerId Provisioned
badProvider = ManagedProviderHandle

badShare ::
  ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned
badShare = ManagedProviderShareHandle
