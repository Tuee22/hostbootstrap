module ProjectFrameAsCommandAuthority where

import HostBootstrap.Authority
    ( CommandAuthority
    , PreparePhase
    , VerbUp
    )
import HostBootstrap.ProjectPlan.Frame (ProjectFrame)

data Scope
data SpecDigest
data PlanId
data ConfigId
data Frame
data BrokerGeneration

consumeCommand ::
    CommandAuthority Scope PlanId Frame BrokerGeneration VerbUp PreparePhase ->
    ()
consumeCommand _ = ()

projectFrameCannotAuthorize :: ProjectFrame Scope SpecDigest PlanId ConfigId Frame -> ()
projectFrameCannotAuthorize frame = consumeCommand frame
