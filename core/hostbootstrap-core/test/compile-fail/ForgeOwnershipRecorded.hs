module ForgeOwnershipRecorded where

import HostBootstrap.Ownership.Clause (Recorded)
import HostBootstrap.Ownership.Object (OriginRecord)

data Session
data Obj

-- Clause 2 is held by publishing the record, never by holding one.
forged :: OriginRecord -> Recorded Session Obj
forged = Recorded
