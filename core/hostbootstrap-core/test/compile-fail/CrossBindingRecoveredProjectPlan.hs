module CrossBindingRecoveredProjectPlan where

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
data DigestA
data DigestB
data PlanId
data BrokerGeneration
data RootId
data ConfigId
data Cfg scope

-- The profile, verified snapshot, and bound snapshot fix DigestA. A binding
-- carrying DigestB cannot enter reconstruction.
wrongBinding ::
    RecoveredProductionLifecycleProfile Project SpecDigest DigestA PlanId BrokerGeneration ->
    CanonicalProjectRoot (Production Project) RootId ->
    VerifiedPlanSnapshot (Production Project) SpecDigest DigestA ->
    BoundPlanSnapshot (Production Project) SpecDigest DigestA PlanId ->
    PlanDigestBinding (Production Project) SpecDigest DigestB PlanId ->
    ValidatedConfig (Production Project) SpecDigest ConfigId (Cfg (Production Project)) ->
    NonEmpty (PlanDraft (Production Project) SpecDigest (Cfg (Production Project))) ->
    Either PlanError ()
wrongBinding profile root verified snapshot binding config drafts =
    withRecoveredProductionProjectPlan
        profile
        root
        verified
        snapshot
        binding
        config
        drafts
        (const ())
