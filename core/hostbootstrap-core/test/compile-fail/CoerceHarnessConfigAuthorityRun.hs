module CoerceHarnessConfigAuthorityRun where

import Data.Coerce (coerce)
import HostBootstrap.Config.Vocab (HarnessConfigAuthority)

data RunA
data RunB

-- Plaintext admission remains bound to the same project and exact Harness run.
wrongRun :: HarnessConfigAuthority projectId RunA -> HarnessConfigAuthority projectId RunB
wrongRun = coerce
