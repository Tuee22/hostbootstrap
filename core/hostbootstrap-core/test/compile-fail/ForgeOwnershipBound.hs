module ForgeOwnershipBound where

import HostBootstrap.Ownership.Clause (Bound)
import HostBootstrap.Ownership.Object (ObjectIdentity, OriginRecord)

data Session
data Obj

-- Clause 3 is held by reading the created object's identity, never by naming one.
forged :: OriginRecord -> ObjectIdentity -> Bound Session Obj
forged = Bound
