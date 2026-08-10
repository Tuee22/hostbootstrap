module CrossBoundSnapshotRecoveredProjectPlan where

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
data SpecDigest
data PlanDigest
data PlanA
data PlanB
data BrokerGeneration
data RootId
data ConfigId
data Cfg scope

-- The profile and binding fix PlanA. A bound snapshot carrying PlanB cannot
-- enter the reconstruction boundary.
wrongBoundSnapshot ::
    RecoveredProductionLifecycleProfile Project SpecDigest PlanDigest PlanA BrokerGeneration ->
    CanonicalProjectRoot (Production Project) RootId ->
    VerifiedPlanSnapshot (Production Project) SpecDigest PlanDigest ->
    BoundPlanSnapshot (Production Project) SpecDigest PlanDigest PlanB ->
    PlanDigestBinding (Production Project) SpecDigest PlanDigest PlanA ->
    ValidatedConfig (Production Project) SpecDigest ConfigId (Cfg (Production Project)) ->
    NonEmpty (PlanDraft (Production Project) SpecDigest (Cfg (Production Project))) ->
    Either PlanError ()
wrongBoundSnapshot profile root verified snapshot binding config drafts =
    withRecoveredProductionProjectPlan
        profile
        root
        verified
        snapshot
        binding
        config
        drafts
        (const ())
