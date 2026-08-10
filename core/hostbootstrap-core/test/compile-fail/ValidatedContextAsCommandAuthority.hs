module ValidatedContextAsCommandAuthority where

import HostBootstrap.Authority
    ( CommandAuthority
    , PreparePhase
    , VerbUp
    )
import HostBootstrap.ProjectPlan.Frame (ValidatedContext)

data Scope
data PlanId
data Frame
data BrokerGeneration

consumeCommand ::
    CommandAuthority Scope PlanId Frame BrokerGeneration VerbUp PreparePhase ->
    ()
consumeCommand _ = ()

validatedContextCannotAuthorize :: ValidatedContext Scope PlanId Frame -> ()
validatedContextCannotAuthorize context = consumeCommand context
