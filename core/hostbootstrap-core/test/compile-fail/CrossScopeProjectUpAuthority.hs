module CrossScopeProjectUpAuthority where

import HostBootstrap.Authority
    ( ProjectVerb (ProjectUp)
    , RootInvocationAuthority
    , VerbUp
    )
import HostBootstrap.Authority.ProjectPlan (authorizeRootProject)
import HostBootstrap.Lifecycle.Mode (VerifiedPlanSnapshot)

data ScopeA
data ScopeB
data BrokerGeneration
data SpecDigest
data PlanDigest

crossScope ::
    RootInvocationAuthority ScopeA BrokerGeneration VerbUp ->
    VerifiedPlanSnapshot ScopeB SpecDigest PlanDigest ->
    ()
crossScope root verified = authorizeRootProject root ProjectUp verified `seq` ()
