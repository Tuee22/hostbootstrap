module ForgeVerifiedRecoveryWire where

import Data.ByteString (ByteString)
import HostBootstrap.Handoff

-- A response signature or raw wire is not a verified recovery value.  The
-- constructor is private; only independent-key verification inside the rank-2
-- producer can mint this type.
promoteRawWire ::
    ByteString ->
    VerifiedRecoveryWire scope brokerGeneration verb planDigest frame wireDigest wireId
promoteRawWire bytes = VerifiedRecoveryWire bytes
