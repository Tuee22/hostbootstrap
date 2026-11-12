module ForgeRootedLifecycleStage where

import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (LifecycleStage(..))

forge :: Text -> LifecycleStage
forge = LifecycleStage
