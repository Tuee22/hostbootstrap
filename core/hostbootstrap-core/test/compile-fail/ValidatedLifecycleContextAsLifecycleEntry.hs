module ValidatedLifecycleContextAsLifecycleEntry where

import HostBootstrap.Authority (VerbUp)
import HostBootstrap.Command (LifecycleEntry, lifecycleEntryFrameName)
import HostBootstrap.Lifecycle.Context (ValidatedLifecycleContext)

data Scope
data Spec
data Plan
data Config
data Frame
data Broker

wrong :: ValidatedLifecycleContext Scope Spec Plan Config Frame -> ()
wrong context = lifecycleEntryFrameName (context :: LifecycleEntry Scope Plan Frame Broker VerbUp) `seq` ()
