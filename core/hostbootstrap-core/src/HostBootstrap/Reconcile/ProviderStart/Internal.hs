{- | Package-private capabilities for completing an exact provider start.

The public reconciliation facade mentions these types in sealed operations but
does not expose this module.  Consequently an ordinary library client cannot
manufacture either a backend success or the projection capability used by the
closed direct-provider settlement bridge.
-}
module HostBootstrap.Reconcile.ProviderStart.Internal
  ( ProviderStartBackendResult (..),
    ProviderStartProjectionAuthority (..),
  )
where

-- | The only backend outcomes that may complete a provider start.
data ProviderStartBackendResult
  = ProviderStartBackendCreated
  | ProviderStartBackendRepaired

-- | Capability for inspecting the generative journal indices of a prepared
-- provider start inside a package-private owning settlement bridge.
data ProviderStartProjectionAuthority = ProviderStartProjectionAuthority
