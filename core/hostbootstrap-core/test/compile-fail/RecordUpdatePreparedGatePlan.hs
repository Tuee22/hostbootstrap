module RecordUpdatePreparedGatePlan where

import Data.Text (Text)
import HostBootstrap.Lifecycle.Prepared (PreparedGate, preparedGatePlan)

replacePlan :: PreparedGate -> Text -> PreparedGate
replacePlan gate replacement = gate{preparedGatePlan = replacement}
