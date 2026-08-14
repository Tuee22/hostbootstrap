module CrossVerbProjectUpAuthority where

import HostBootstrap.Authority
    ( ProjectVerb (ProjectDown)
    , RootInvocationAuthority
    , VerbDown
    , VerbUp
    )
import HostBootstrap.Authority.ProjectPlan (authorizeRootProject)

data Scope
data BrokerGeneration

crossVerb :: RootInvocationAuthority Scope BrokerGeneration VerbUp -> ()
crossVerb root = authorizeRootProject root (ProjectDown :: ProjectVerb VerbDown) `seq` ()
