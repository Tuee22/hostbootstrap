module CoerceHarnessModeRun where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (HarnessMode)

data RunA
data RunB

-- HarnessMode's run parameter is nominal: representation equality cannot
-- relabel one generative run as another.
wrongRun :: HarnessMode RunA -> HarnessMode RunB
wrongRun = coerce
