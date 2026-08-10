module CrossRecoveredConfigSpecRecoveredProjectPlan where

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
import HostBootstrap.ProjectScope (Production)

data Project
data SpecA
data SpecB
data PlanDigest
data PlanId
data BrokerGeneration
data RootId
data ConfigId
data Cfg scope

-- The lower recovered constructor still requires its refined config and drafts
-- to carry the recovered profile's exact specification identity.
wrongRecoveredConfig ::
    RecoveredProductionLifecycleProfile Project SpecA PlanDigest PlanId BrokerGeneration ->
    CanonicalProjectRoot (Production Project) RootId ->
    VerifiedPlanSnapshot (Production Project) SpecA PlanDigest ->
    BoundPlanSnapshot (Production Project) SpecA PlanDigest PlanId ->
    PlanDigestBinding (Production Project) SpecA PlanDigest PlanId ->
    ValidatedConfig (Production Project) SpecB ConfigId (Cfg (Production Project)) ->
    NonEmpty (PlanDraft (Production Project) SpecA (Cfg (Production Project))) ->
    Either PlanError ()
wrongRecoveredConfig profile root verified snapshot binding config drafts =
    withRecoveredProductionProjectPlan
        profile
        root
        verified
        snapshot
        binding
        config
        drafts
        (const ())
