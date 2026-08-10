module ForgeProviderCapability where

import HostBootstrap.Substrate.Provider

data Scope
data PlanId
data ProviderId
data BackendId
data CapabilityId

-- The discovery transition is the only public capability mint.
forgedCapability :: ProviderCapability Scope PlanId ProviderId BackendId CapabilityId
forgedCapability = ProviderCapability undefined undefined undefined undefined
