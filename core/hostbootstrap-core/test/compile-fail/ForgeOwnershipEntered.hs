module ForgeOwnershipEntered where

import HostBootstrap.Ownership.Clause (Entered)
import HostBootstrap.Ownership.Object (Origin)

data Session
data Obj

-- Clause 1 is held by entering exclusively, never by asserting that it was.
forged :: Origin -> Entered Session Obj
forged = Entered
