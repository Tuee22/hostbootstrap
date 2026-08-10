module CrossConfigSpecRecoveredProjectPlan where

import HostBootstrap.Config.Schema (ValidatedConfig)
import HostBootstrap.Lifecycle.Mode (RecoveredProductionLifecycleProfile)
import HostBootstrap.ProjectPlan (PlanError)
import HostBootstrap.ProjectPlan.Construct
    ( FinalizedProjectSpec
    , withRecoveredProductionProjectPlanInputs
    )
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.ProjectScope (Production)

data Project
data RecoveredSpec
data CandidateSpecA
data CandidateSpecB
data PlanDigest
data PlanId
data BrokerGeneration
data RootId
data ConfigId
data Cfg scope

-- A candidate finalized definition and candidate config must share the same
-- independently generated specification identity before runtime refinement.
wrongCandidateConfig ::
    RecoveredProductionLifecycleProfile Project RecoveredSpec PlanDigest PlanId BrokerGeneration ->
    CanonicalProjectRoot (Production Project) RootId ->
    FinalizedProjectSpec (Production Project) CandidateSpecA Cfg ->
    ValidatedConfig
        (Production Project)
        CandidateSpecB
        ConfigId
        (Cfg (Production Project)) ->
    Either PlanError ()
wrongCandidateConfig profile root spec config =
    withRecoveredProductionProjectPlanInputs
        profile
        root
        spec
        config
        (\_refined _drafts -> ())
