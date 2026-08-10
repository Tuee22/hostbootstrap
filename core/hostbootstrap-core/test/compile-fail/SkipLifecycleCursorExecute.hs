module SkipLifecycleCursorExecute where

import HostBootstrap.Authority (ExecutePhase, PreparePhase, VerbUp)
import HostBootstrap.Lifecycle.Session
    ( LifecycleCursor
    , LifecycleError
    , withTeardownLifecycleCursor
    )

data Scope
data PlanId
data Frame
data BrokerGeneration

-- Teardown cannot be entered directly from Prepare; Execute is the only
-- predecessor accepted by the transition API.
consumeExecute ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbUp ExecutePhase ->
    IO (Either LifecycleError ())
consumeExecute cursor = withTeardownLifecycleCursor cursor (\_ -> pure ())

skipExecute ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbUp PreparePhase ->
    IO (Either LifecycleError ())
skipExecute cursor = consumeExecute cursor
