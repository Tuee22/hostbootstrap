{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Package-private child plan admission. A child retains authenticated plan
identity; root-selected grants are its only execution authority.
-}
module HostBootstrap.ProjectPlan.Child.Internal (
    ChildPlanAuthority,
    mintChildPlanAuthorityKernel,
    childPlanAuthorityBindingKernel,
) where

import HostBootstrap.Authority (LifecyclePhase)
import HostBootstrap.Config.Schema (
    VerifiedConfigHandoff,
    verifiedConfigHandoffBinding,
    verifiedConfigHandoffPhase,
 )
import HostBootstrap.Handoff (HandoffBinding)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Snapshot (PlanDigestBinding)

data
    ChildPlanAuthority
        scope
        specDigest
        planDigest
        brokerGeneration
        parentFrame
        childFrame
        planId
        configId
        verb
        phase
    where
    ChildPlanAuthority ::
        HandoffBinding scope brokerGeneration ->
        LifecyclePhase phase ->
        ChildPlanAuthority
            scope
            specDigest
            planDigest
            brokerGeneration
            parentFrame
            childFrame
            planId
            configId
            verb
            phase

type role ChildPlanAuthority nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

instance
    Show
        ( ChildPlanAuthority
            scope
            specDigest
            planDigest
            brokerGeneration
            parentFrame
            childFrame
            planId
            configId
            verb
            phase
        )
    where
    show (ChildPlanAuthority binding phase) =
        "ChildPlanAuthority " <> show binding <> " " <> show phase

mintChildPlanAuthorityKernel ::
    VerifiedConfigHandoff
        scope
        planDigest
        brokerGeneration
        parentFrame
        childFrame
        configId
        verb
        phase ->
    ProjectPlan scope specDigest planId configId cfg ->
    PlanDigestBinding scope specDigest planDigest planId ->
    ChildPlanAuthority
        scope
        specDigest
        planDigest
        brokerGeneration
        parentFrame
        childFrame
        planId
        configId
        verb
        phase
mintChildPlanAuthorityKernel handoff plan binding =
    plan `seq`
        binding `seq`
            ChildPlanAuthority
                (verifiedConfigHandoffBinding handoff)
                (verifiedConfigHandoffPhase handoff)

childPlanAuthorityBindingKernel ::
    ChildPlanAuthority
        scope
        specDigest
        planDigest
        brokerGeneration
        parentFrame
        childFrame
        planId
        configId
        verb
        phase ->
    HandoffBinding scope brokerGeneration
childPlanAuthorityBindingKernel (ChildPlanAuthority binding _) = binding
