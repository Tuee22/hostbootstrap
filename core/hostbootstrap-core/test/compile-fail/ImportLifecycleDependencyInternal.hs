module ImportLifecycleDependencyInternal where

import HostBootstrap.Lifecycle.Dependency.Internal (RuntimeDependencyPackage)

data Scope
data Plan

forged :: RuntimeDependencyPackage Scope Plan
forged = undefined
