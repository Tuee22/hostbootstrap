{-# LANGUAGE RankNTypes #-}

module QuantifyRecoveredProductionPlanIdentity where

import HostBootstrap.Authority (RootInvocationAuthority, VerbUp)
import HostBootstrap.Lifecycle.Mode
    ( BoundInvocationRecovery
    , BoundRunLease
    , ModeError
    , ProductionMode
    , ProjectModeLease
    , RecoveredProductionLifecycleProfile
    , VerifiedPlanSnapshot
    , withRecoveredProductionLifecycleProfile
    )
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    )
import HostBootstrap.ProjectScope (Production)

data UniversallyRecovered projectId specDigest planDigest brokerGeneration
    = UniversallyRecovered
        ( forall freshPlanId.
          RecoveredProductionLifecycleProfile
            projectId
            specDigest
            planDigest
            freshPlanId
            brokerGeneration
        )

-- The opener retains the caller's existing planId. It cannot package that
-- profile as evidence valid for a freshly selected recovery identity.
quantifyFreshPlan ::
    RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
    ProjectModeLease projectId ProductionMode brokerGeneration ->
    BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
    VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
    BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
    PlanDigestBinding (Production projectId) specDigest planDigest planId ->
    BoundInvocationRecovery
        (Production projectId)
        specDigest
        planDigest
        planId
        brokerGeneration ->
    Either
        ModeError
        (UniversallyRecovered projectId specDigest planDigest brokerGeneration)
quantifyFreshPlan root mode bound verified snapshot binding recovery =
    withRecoveredProductionLifecycleProfile
        root
        mode
        bound
        verified
        snapshot
        binding
        recovery
        UniversallyRecovered
