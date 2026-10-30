module RecordUpdatePreparedGateFence where

import Data.Word (Word64)
import HostBootstrap.Lifecycle.Prepared (PreparedGate, preparedGateFence)

replaceFence :: PreparedGate -> Word64 -> PreparedGate
replaceFence gate replacement = gate{preparedGateFence = replacement}
