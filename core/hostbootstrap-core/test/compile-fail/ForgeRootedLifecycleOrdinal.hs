module ForgeRootedLifecycleOrdinal where

import Data.Word (Word64)
import HostBootstrap.Handoff.Rooted (LifecycleOrdinal(..))

forge :: Word64 -> LifecycleOrdinal
forge = LifecycleOrdinal
