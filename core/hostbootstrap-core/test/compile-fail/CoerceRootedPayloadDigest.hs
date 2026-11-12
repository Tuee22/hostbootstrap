module CoerceRootedPayloadDigest where

import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (PayloadDigest)

retag :: Text -> PayloadDigest
retag = coerce
