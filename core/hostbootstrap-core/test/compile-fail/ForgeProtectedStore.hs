module ForgeProtectedStore where

import HostBootstrap.Protected (ProtectedStore)

forged :: ProtectedStore
forged = ProtectedStore "/tmp" undefined undefined undefined
