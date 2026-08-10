module CoerceProviderCapabilityIdentity where

import Data.Coerce (coerce)
import HostBootstrap.Substrate.Provider

data CapabilityA
data CapabilityB
data Scope
data PlanId
data ProviderId
data BackendId

-- Nominal identity prevents representational relabelling across discoveries.
wrongCapabilityIdentity ::
    ProviderCapability Scope PlanId ProviderId BackendId CapabilityA ->
    ProviderCapability Scope PlanId ProviderId BackendId CapabilityB
wrongCapabilityIdentity = coerce
