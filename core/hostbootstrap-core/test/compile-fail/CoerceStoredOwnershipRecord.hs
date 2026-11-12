module CoerceStoredOwnershipRecord where

import Data.Coerce (coerce)
import HostBootstrap.Ownership.Primitive (StoredOriginRecord)

data First = First
data Second = Second

-- The constructor is private and the entry index is nominal.
changesEntry :: StoredOriginRecord First -> StoredOriginRecord Second
changesEntry = coerce
