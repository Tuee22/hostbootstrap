module RecordUpdatePreparedGateJournalVersion where

import Data.Word (Word64)
import HostBootstrap.Lifecycle.Prepared (PreparedGate, preparedGateJournalVersion)

replaceJournalVersion :: PreparedGate -> Word64 -> PreparedGate
replaceJournalVersion gate replacement = gate{preparedGateJournalVersion = replacement}
