module ForgeOperationSession where

import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Lifecycle.Session (OperationSession, SessionId)

forgedSession :: SessionId -> Text -> Word64 -> OperationSession scope planId
forgedSession session plan generation = OperationSession session plan generation
