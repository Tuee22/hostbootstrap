{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE OverloadedStrings #-}

module CrossFenceEpochPreparedSession where

import HostBootstrap.Authority
import HostBootstrap.Lifecycle.Session
import HostBootstrap.Protected

data Scope
data PlanA
data PlanB

prepareWithAnotherPlanFence ::
    ProtectedSession session ->
    OperationSession Scope PlanB ->
    BrokerEpoch generation ->
    FenceEpoch Scope PlanA ->
    ProjectPermit Scope PlanB ->
    IO (Either SessionError ())
prepareWithAnotherPlanFence session operations broker fence permit =
    HostBootstrap.Lifecycle.Session.withPreparedGate
        session
        operations
        broker
        fence
        "operation"
        "EffectOutcomeUnknown"
        permit
        (\_ _ -> pure (Right ()))
