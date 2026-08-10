{-# LANGUAGE RoleAnnotations #-}

{- | Package-private representation of child plan authority.

Only the child-plan admission facade can mint this value.  Keeping the
constructor in an unexposed module prevents transport verification by itself
from becoming plan or command authority.
-}
module HostBootstrap.ProjectPlan.Child.Internal
    ( ChildPlanAuthority
    , mintChildPlanAuthorityKernel
    , childPlanAuthorityBindingKernel
    )
where

import HostBootstrap.Config.Schema
    ( VerifiedConfigHandoff
    , verifiedConfigHandoffBinding
    )
import HostBootstrap.Handoff (HandoffBinding)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Snapshot (PlanDigestBinding)

newtype ChildPlanAuthority
    scope specDigest planDigest brokerGeneration parentFrame childFrame
    planId configId verb phase
    = ChildPlanAuthority (HandoffBinding scope brokerGeneration)

type role ChildPlanAuthority nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

instance
    Show
        ( ChildPlanAuthority
            scope specDigest planDigest brokerGeneration parentFrame childFrame
            planId configId verb phase
        )
    where
    show (ChildPlanAuthority binding) = "ChildPlanAuthority " <> show binding

mintChildPlanAuthorityKernel ::
    VerifiedConfigHandoff
        scope planDigest brokerGeneration parentFrame childFrame configId verb phase ->
    ProjectPlan scope specDigest planId configId cfg ->
    PlanDigestBinding scope specDigest planDigest planId ->
    ChildPlanAuthority
        scope specDigest planDigest brokerGeneration parentFrame childFrame
        planId configId verb phase
mintChildPlanAuthorityKernel handoff plan binding =
    plan `seq` binding `seq` ChildPlanAuthority (verifiedConfigHandoffBinding handoff)

childPlanAuthorityBindingKernel ::
    ChildPlanAuthority
        scope specDigest planDigest brokerGeneration parentFrame childFrame
        planId configId verb phase ->
    HandoffBinding scope brokerGeneration
childPlanAuthorityBindingKernel (ChildPlanAuthority binding) = binding
