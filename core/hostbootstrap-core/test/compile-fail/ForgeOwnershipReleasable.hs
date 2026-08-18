module ForgeOwnershipReleasable where

import HostBootstrap.Ownership.Clause (Releasable)
import HostBootstrap.Ownership.Object (ObjectIdentity, OriginRecord)

data Session
data Obj

-- Clause 4's precondition is held by re-observing the identity, never by
-- deciding it still matches.
forged :: OriginRecord -> ObjectIdentity -> Releasable Session Obj
forged = Releasable
