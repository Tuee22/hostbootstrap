{- | Production closure compatibility vocabulary.

This later-owned module keeps the current root/evidence close protocol outside
the lower authority facade. The recovery-and-migration phase supplies the
proof-complete Production closure authorization consumed by final mode release.
-}
module HostBootstrap.Lifecycle.Closure (
    ProductionCloseRoot,
    destroyCloseRoot,
    preEffectCloseRoot,
    productionCloseRootVerb,
    ProductionCloseKind (..),
) where

import HostBootstrap.Authority.Kernel (
    ProductionCloseKind (..),
    ProductionCloseRoot,
    destroyCloseRoot,
    preEffectCloseRoot,
    productionCloseRootVerb,
 )
