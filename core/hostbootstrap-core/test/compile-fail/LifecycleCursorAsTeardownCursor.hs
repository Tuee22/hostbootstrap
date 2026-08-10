module LifecycleCursorAsTeardownCursor where

import HostBootstrap.Authority (TeardownPhase, VerbDown)
import HostBootstrap.Lifecycle.Session (LifecycleCursor)
import HostBootstrap.Teardown (DownVerb, TeardownCursor)

data Scope
data PlanId
data Frame
data BrokerGeneration

consumeTeardown :: TeardownCursor Scope PlanId DownVerb -> ()
consumeTeardown _ = ()

-- The phase cursor cannot substitute for the reverse-projection scheduler's
-- resource-specific teardown authority.
cursorCannotTeardown ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbDown TeardownPhase ->
    ()
cursorCannotTeardown cursor = consumeTeardown cursor
