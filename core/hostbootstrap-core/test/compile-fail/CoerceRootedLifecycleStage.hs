module CoerceRootedLifecycleStage where

import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (LifecycleStage(..))

retag :: Text -> LifecycleStage
retag = coerce
