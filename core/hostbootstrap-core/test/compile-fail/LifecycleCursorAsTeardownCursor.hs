module LifecycleCursorAsTeardownCursor where

import HostBootstrap.Authority (TeardownPhase, VerbDown)
import HostBootstrap.Lifecycle.Session (LifecycleCursor)
import HostBootstrap.Teardown (LocalWork)

data Scope
data PlanId
data Frame
data BrokerGeneration

consumeTeardown :: LocalWork Scope PlanId Frame VerbDown -> ()
consumeTeardown _ = ()

-- The phase cursor cannot substitute for the reverse scheduler's local-work
-- package: they carry different authority and advance different state machines.
cursorCannotTeardown ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbDown TeardownPhase ->
    ()
cursorCannotTeardown cursor = consumeTeardown cursor
