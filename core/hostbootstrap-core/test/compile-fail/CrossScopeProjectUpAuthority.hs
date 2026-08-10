module CrossScopeProjectUpAuthority where

import HostBootstrap.Authority
    ( ProjectVerb (ProjectUp)
    , RootInvocationAuthority
    , VerbUp
    )
import HostBootstrap.Authority.ProjectPlan (authorizeProjectUp)
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
crossScope root verified = authorizeProjectUp root ProjectUp verified `seq` ()
