module ForgeLifecycleCursor where

import HostBootstrap.Lifecycle.Session (LifecycleCursor)

data Scope
data PlanId
data Frame
data BrokerGeneration
data Verb
data Phase

-- Only the lifecycle journal may mint a cursor for an exact frame and phase.
forgedCursor :: LifecycleCursor Scope PlanId Frame BrokerGeneration Verb Phase
forgedCursor = LifecycleCursor
