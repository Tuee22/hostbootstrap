{- | The durable unknown-phase write is the only producer of a 'PreparedGate'
(§ EE): a caller can neither construct one from an attempt and journal
version of its own nor update the indices on one it was handed.
-}
module ForgePreparedGate where

import HostBootstrap.Lifecycle.Prepared

forgedGate :: PreparedGate
forgedGate =
    PreparedGate
        { preparedGatePlan = "plan"
        , preparedGateOperation = "core:deploy-kind"
        , preparedGateSession = "session-1"
        , preparedGateFence = 1
        , preparedGateAttempt = 1
        , preparedGateJournalVersion = 1
        }

relabelledGate :: PreparedGate -> PreparedGate
relabelledGate gate = gate{preparedGateOperation = "core:deploy-vm"}
