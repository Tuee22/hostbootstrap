module CurrentFrameAsCommandAuthority where

import HostBootstrap.Authority
    ( CommandAuthority
    , PreparePhase
    , VerbUp
    )
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)

data Scope
data PlanId
data Frame
data BrokerGeneration

consumeCommand ::
    CommandAuthority Scope PlanId Frame BrokerGeneration VerbUp PreparePhase ->
    ()
consumeCommand _ = ()

currentFrameCannotAuthorize :: CurrentFrame Scope PlanId Frame -> ()
currentFrameCannotAuthorize frame = consumeCommand frame
