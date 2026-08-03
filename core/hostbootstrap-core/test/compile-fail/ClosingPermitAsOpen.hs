{-# LANGUAGE OverloadedStrings #-}

module ClosingPermitAsOpen where

import HostBootstrap.Authority (BrokerEpoch)
import HostBootstrap.Lifecycle.Session
import HostBootstrap.Protected (ProtectedSession)

-- A current Closing permit may resume/finalize its exact close journal, but it
-- must never satisfy an API that can advance an Open project journal.
reopenWithClosing ::
    ProtectedSession session ->
    BrokerEpoch brokerGeneration ->
    ProjectPermit scope planId ->
    IO (Either SessionError ())
reopenWithClosing session epoch openPermit = do
    closing <- beginClosingProject session "plan" 7 openPermit
    case closing of
        Left failure -> pure (Left failure)
        Right closingPermit ->
            fmap
                (fmap (const ()))
                (openOperationSession session epoch "plan" "session-b" closingPermit)
