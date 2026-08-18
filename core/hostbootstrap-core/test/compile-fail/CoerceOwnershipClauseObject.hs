module CoerceOwnershipClauseObject where

import Data.Coerce (coerce)
import HostBootstrap.Ownership.Clause (Bound)

data Session
data ObjA
data ObjB

-- The object index is nominal: evidence gathered for one owned object is not
-- evidence about another.
coerced :: Bound Session ObjA -> Bound Session ObjB
coerced = coerce
