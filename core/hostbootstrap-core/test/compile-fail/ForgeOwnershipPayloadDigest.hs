module ForgeOwnershipPayloadDigest where

import Data.Text (Text)
import HostBootstrap.Ownership.Object (PayloadDigest)

-- A digest is computed from the payload this run intends to install, never
-- supplied as text.
forged :: Text -> PayloadDigest
forged = PayloadDigest
