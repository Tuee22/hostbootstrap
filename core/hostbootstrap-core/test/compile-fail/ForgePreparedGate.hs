{- | A caller cannot name the 'PreparedGate' constructor to choose its own
durable coordinates (§ EE).
-}
module ForgePreparedGate where

import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Lifecycle.Prepared (PreparedGate (PreparedGate))

forgedGate :: Text -> Text -> Text -> Word64 -> Word64 -> Word64 -> PreparedGate
forgedGate plan operation session fence attempt version =
    PreparedGate plan operation session fence attempt version
