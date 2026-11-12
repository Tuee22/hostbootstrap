module ForgeRootedChildConfigDigest where

import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (ChildConfigDigest(..))

forge :: Text -> ChildConfigDigest
forge = ChildConfigDigest
