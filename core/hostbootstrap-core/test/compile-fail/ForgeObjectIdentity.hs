module ForgeObjectIdentity where

import Data.ByteString (ByteString)
import HostBootstrap.Ownership.Object (ObjectIdentity)

-- An identity is the kernel's answer, so no caller may build one from bytes.
forged :: ByteString -> ObjectIdentity
forged = ObjectIdentity
