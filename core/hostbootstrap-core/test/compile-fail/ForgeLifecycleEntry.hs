module ForgeLifecycleEntry where

import HostBootstrap.Command (LifecycleEntry)

forge :: LifecycleEntry scope plan frame broker verb
forge = LifecycleEntry
