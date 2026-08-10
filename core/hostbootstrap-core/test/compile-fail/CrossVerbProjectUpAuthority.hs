module CrossVerbProjectUpAuthority where

import HostBootstrap.Authority
    ( ProjectVerb (ProjectDown)
    , RootInvocationAuthority
    , VerbDown
    , VerbUp
    )
import HostBootstrap.Authority.ProjectPlan (authorizeProjectUp)

data Scope
data BrokerGeneration

crossVerb :: RootInvocationAuthority Scope BrokerGeneration VerbUp -> ()
crossVerb root = authorizeProjectUp root (ProjectDown :: ProjectVerb VerbDown) `seq` ()
