module RawCallbackAsShareDependency where

import Data.Word (Word64)
import HostBootstrap.Reconcile (ReconcileError)
import HostBootstrap.Substrate.Provider.Reconcile (ProviderShareDependency)

bad :: IO (Either ReconcileError Word64) -> ProviderShareDependency scope planId shareId
bad = id
