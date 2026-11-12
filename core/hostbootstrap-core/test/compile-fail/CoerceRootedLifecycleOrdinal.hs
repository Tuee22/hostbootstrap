module CoerceRootedLifecycleOrdinal where

import Data.Coerce (coerce)
import Data.Word (Word64)
import HostBootstrap.Handoff.Rooted (LifecycleOrdinal(..))

retag :: Word64 -> LifecycleOrdinal
retag = coerce
