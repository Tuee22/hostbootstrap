module RecordUpdatePreparedGateOperation where

import Data.Text (Text)
import HostBootstrap.Lifecycle.Prepared (PreparedGate, preparedGateOperation)

replaceOperation :: PreparedGate -> Text -> PreparedGate
replaceOperation gate replacement = gate{preparedGateOperation = replacement}
