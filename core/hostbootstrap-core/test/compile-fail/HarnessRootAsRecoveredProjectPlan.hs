module HarnessRootAsRecoveredProjectPlan where

import Data.List.NonEmpty (NonEmpty)
import HostBootstrap.Config.Schema (ValidatedConfig)
import HostBootstrap.Lifecycle.Mode
    ( RecoveredProductionLifecycleProfile
    , VerifiedPlanSnapshot
    )
import HostBootstrap.ProjectPlan
    ( PlanDraft
    , PlanError
    )
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

-- Recovered plan construction is Production-only. A Harness root cannot be
-- substituted even when every plan-indexed value is otherwise exact.
wrongRoot ::
    RecoveredProductionLifecycleProfile Project SpecDigest PlanDigest PlanId BrokerGeneration ->
    CanonicalProjectRoot (Harness Project Run) RootId ->
    VerifiedPlanSnapshot (Production Project) SpecDigest PlanDigest ->
    BoundPlanSnapshot (Production Project) SpecDigest PlanDigest PlanId ->
    PlanDigestBinding (Production Project) SpecDigest PlanDigest PlanId ->
    ValidatedConfig (Production Project) SpecDigest ConfigId (Cfg (Production Project)) ->
    NonEmpty (PlanDraft (Production Project) SpecDigest (Cfg (Production Project))) ->
    Either PlanError ()
wrongRoot profile root verified snapshot binding config drafts =
    withRecoveredProductionProjectPlan
        profile
        root
        verified
        snapshot
        binding
        config
        drafts
        (const ())
