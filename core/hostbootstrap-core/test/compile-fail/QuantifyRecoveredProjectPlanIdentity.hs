{-# LANGUAGE RankNTypes #-}

module QuantifyRecoveredProjectPlanIdentity where

import Data.List.NonEmpty (NonEmpty)
import HostBootstrap.Config.Schema (ValidatedConfig)
import HostBootstrap.Lifecycle.Mode
    ( RecoveredProductionLifecycleProfile
    , VerifiedPlanSnapshot
    )
import HostBootstrap.ProjectPlan
    ( PlanDraft
    , PlanError
    , ProjectPlan
    )
import HostBootstrap.ProjectPlan.Construct (withRecoveredProductionProjectPlan)
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    )
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.ProjectScope (Production)

data UniversallyRecoveredPlan projectId specDigest configId cfg
    = UniversallyRecoveredPlan
        ( forall freshPlanId.
          ProjectPlan
            (Production projectId)
            specDigest
            freshPlanId
            configId
            cfg
        )

-- Reconstruction retains the admission-generated planId. Its result cannot
-- be packaged as a plan valid for every freshly selected identity.
quantifyFreshPlan ::
    RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration ->
    CanonicalProjectRoot (Production projectId) rootId ->
    VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
    BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
    PlanDigestBinding (Production projectId) specDigest planDigest planId ->
    ValidatedConfig
        (Production projectId)
        specDigest
        configId
        (cfg (Production projectId)) ->
    NonEmpty
        (PlanDraft (Production projectId) specDigest (cfg (Production projectId))) ->
    Either
        PlanError
        (UniversallyRecoveredPlan projectId specDigest configId cfg)
quantifyFreshPlan profile root verified snapshot binding config drafts =
    withRecoveredProductionProjectPlan
        profile
        root
        verified
        snapshot
        binding
        config
        drafts
        UniversallyRecoveredPlan
