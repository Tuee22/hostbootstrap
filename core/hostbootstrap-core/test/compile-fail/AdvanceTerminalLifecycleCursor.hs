module AdvanceTerminalLifecycleCursor where

import HostBootstrap.Authority (ExecutePhase, TeardownPhase, VerbUp)
import HostBootstrap.Lifecycle.Session
    ( LifecycleCursor
    , LifecycleError
    , withTeardownLifecycleCursor
    )

data Scope
data PlanId
data Frame
data BrokerGeneration

-- Teardown is terminal: its cursor cannot be supplied to the only transition
-- that produces a Teardown successor.
consumeExecute ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbUp ExecutePhase ->
    IO (Either LifecycleError ())
consumeExecute cursor = withTeardownLifecycleCursor cursor (\_ -> pure ())

advanceTerminal ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbUp TeardownPhase ->
    IO (Either LifecycleError ())
advanceTerminal cursor = consumeExecute cursor
