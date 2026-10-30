module RecordUpdatePreparedGateAttempt where

import Data.Word (Word64)
import HostBootstrap.Lifecycle.Prepared (PreparedGate, preparedGateAttempt)

replaceAttempt :: PreparedGate -> Word64 -> PreparedGate
replaceAttempt gate replacement = gate{preparedGateAttempt = replacement}
