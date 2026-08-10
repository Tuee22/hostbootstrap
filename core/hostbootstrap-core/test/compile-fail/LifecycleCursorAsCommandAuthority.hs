module LifecycleCursorAsCommandAuthority where

import HostBootstrap.Authority
    ( CommandAuthority
    , PreparePhase
    , VerbUp
    )
import HostBootstrap.Lifecycle.Session (LifecycleCursor)

data Scope
data PlanId
data Frame
data BrokerGeneration

consumeCommand ::
    CommandAuthority Scope PlanId Frame BrokerGeneration VerbUp PreparePhase ->
    ()
consumeCommand _ = ()

-- A lifecycle position is descriptive evidence, not command authority.
cursorCannotAuthorize ::
    LifecycleCursor Scope PlanId Frame BrokerGeneration VerbUp PreparePhase ->
    ()
cursorCannotAuthorize cursor = consumeCommand cursor
