module CoerceHarnessAuthorityRun where

import Data.Coerce (coerce)
import HostBootstrap.Config.Vocab (HarnessAuthority)

data RunA
data RunB

-- Keeping the project fixed cannot transfer authority to another Harness run.
wrongRun :: HarnessAuthority projectId RunA -> HarnessAuthority projectId RunB
wrongRun = coerce
