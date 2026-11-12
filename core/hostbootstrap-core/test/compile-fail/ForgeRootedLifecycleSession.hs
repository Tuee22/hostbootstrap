module ForgeRootedLifecycleSession where

import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (LifecycleSession(..))

forge :: Text -> LifecycleSession
forge = LifecycleSession
