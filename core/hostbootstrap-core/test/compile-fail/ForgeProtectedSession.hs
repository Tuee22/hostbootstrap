module ForgeProtectedSession where

import HostBootstrap.Protected

-- A session is proof that the caller is inside the exclusive entry. Forging one
-- would let a record operation run without the lock.
forgedSession :: ProtectedSession session
forgedSession = ProtectedSession undefined
