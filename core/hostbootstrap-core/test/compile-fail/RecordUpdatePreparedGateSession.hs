module RecordUpdatePreparedGateSession where

import Data.Text (Text)
import HostBootstrap.Lifecycle.Prepared (PreparedGate, preparedGateSession)

replaceSession :: PreparedGate -> Text -> PreparedGate
replaceSession gate replacement = gate{preparedGateSession = replacement}
