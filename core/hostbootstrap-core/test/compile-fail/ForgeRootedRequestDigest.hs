module ForgeRootedRequestDigest where

import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (RequestDigest(..))

forge :: Text -> RequestDigest
forge = RequestDigest
