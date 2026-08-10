module CoerceRunId where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (RunId)

data RunA
data RunB

-- The generative phantom is nominal even though the stable diagnostic text has
-- the same representation for every run.
wrongRun :: RunId RunA -> RunId RunB
wrongRun = coerce
