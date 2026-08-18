module CoerceOwnershipClauseSession where

import Data.Coerce (coerce)
import HostBootstrap.Ownership.Clause (Bound)

data SessionA
data SessionB
data Obj

-- The entry index is nominal: evidence authorized by one protected entry is not
-- evidence authorized by another.
coerced :: Bound SessionA Obj -> Bound SessionB Obj
coerced = coerce
