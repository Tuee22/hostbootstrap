module CoerceRootedChildConfigDigest where

import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (ChildConfigDigest(..))

retag :: Text -> ChildConfigDigest
retag = coerce
