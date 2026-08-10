module HarnessDraftsAsRecoveredProjectPlan where

import Data.List.NonEmpty (NonEmpty)
import HostBootstrap.Config.Schema (ValidatedConfig)
import HostBootstrap.Lifecycle.Mode
    ( RecoveredProductionLifecycleProfile
    , VerifiedPlanSnapshot
    )
import HostBootstrap.ProjectPlan (PlanDraft, PlanError)
import HostBootstrap.ProjectPlan.Construct (withRecoveredProductionProjectPlan)
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    )
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.ProjectScope (Harness, Production)

data Project
data Run
data SpecDigest
data PlanDigest
data PlanId
data BrokerGeneration
data RootId
data ConfigId
data Cfg scope

-- Harness drafts cannot be interpreted under a recovered Production package.
wrongDraftScope ::
    RecoveredProductionLifecycleProfile Project SpecDigest PlanDigest PlanId BrokerGeneration ->
    CanonicalProjectRoot (Production Project) RootId ->
    VerifiedPlanSnapshot (Production Project) SpecDigest PlanDigest ->
    BoundPlanSnapshot (Production Project) SpecDigest PlanDigest PlanId ->
    PlanDigestBinding (Production Project) SpecDigest PlanDigest PlanId ->
    ValidatedConfig (Production Project) SpecDigest ConfigId (Cfg (Production Project)) ->
    NonEmpty (PlanDraft (Harness Project Run) SpecDigest (Cfg (Harness Project Run))) ->
    Either PlanError ()
wrongDraftScope profile root verified snapshot binding config drafts =
    withRecoveredProductionProjectPlan
        profile
        root
        verified
        snapshot
        binding
        config
        drafts
        (const ())
