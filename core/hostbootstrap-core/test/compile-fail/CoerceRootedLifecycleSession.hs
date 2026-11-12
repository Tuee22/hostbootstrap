module CoerceRootedLifecycleSession where

import Data.Coerce (coerce)
import Data.Text (Text)
import HostBootstrap.Handoff.Rooted (LifecycleSession(..))

retag :: Text -> LifecycleSession
retag = coerce
