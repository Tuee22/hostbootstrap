module ForgeRootedPayloadDigest where

import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (PayloadDigest)

forge :: Text -> PayloadDigest
forge = PayloadDigest
