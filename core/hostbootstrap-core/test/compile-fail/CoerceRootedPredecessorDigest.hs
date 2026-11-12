module CoerceRootedPredecessorDigest where

import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (PredecessorDigest(..))

retag :: Text -> PredecessorDigest
retag = coerce
