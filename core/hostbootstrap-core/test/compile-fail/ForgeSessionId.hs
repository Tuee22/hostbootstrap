module ForgeSessionId where

import Data.Text (Text)
import HostBootstrap.Lifecycle.Session (SessionId)

forgedSessionId :: Text -> SessionId
forgedSessionId name = SessionId name
