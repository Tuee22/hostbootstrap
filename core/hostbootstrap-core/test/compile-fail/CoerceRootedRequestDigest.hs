module CoerceRootedRequestDigest where

import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (RequestDigest(..))

retag :: Text -> RequestDigest
retag = coerce
