module ForgeValidatedLifecycleContext where

import HostBootstrap.Lifecycle.Context (ValidatedLifecycleContext)

data Scope
data Specification
data Plan
data Configuration
data Frame

forged :: ValidatedLifecycleContext Scope Specification Plan Configuration Frame
forged = ValidatedLifecycleContext
