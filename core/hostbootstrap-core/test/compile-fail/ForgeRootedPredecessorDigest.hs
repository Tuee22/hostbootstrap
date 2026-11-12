module ForgeRootedPredecessorDigest where

import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (PredecessorDigest(..))

forge :: Text -> PredecessorDigest
forge = PredecessorDigest
