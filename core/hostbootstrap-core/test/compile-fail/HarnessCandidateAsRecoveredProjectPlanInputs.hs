module HarnessCandidateAsRecoveredProjectPlanInputs where

import HostBootstrap.Config.Schema (ValidatedConfig)
import HostBootstrap.Lifecycle.Mode (RecoveredProductionLifecycleProfile)
import HostBootstrap.ProjectPlan (PlanError)
import HostBootstrap.ProjectPlan.Construct
    ( FinalizedProjectSpec
    , withRecoveredProductionProjectPlanInputs
    )
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.ProjectScope (Harness, Production)

data Project
data Run
data RecoveredSpec
data CandidateSpec
data PlanDigest
data PlanId
data BrokerGeneration
data RootId
data ConfigId
data Cfg scope

-- A Harness candidate definition/config cannot be refined for a recovered
-- Production profile.
wrongCandidateScope ::
    RecoveredProductionLifecycleProfile Project RecoveredSpec PlanDigest PlanId BrokerGeneration ->
    CanonicalProjectRoot (Production Project) RootId ->
    FinalizedProjectSpec (Harness Project Run) CandidateSpec Cfg ->
    ValidatedConfig
        (Harness Project Run)
        CandidateSpec
        ConfigId
        (Cfg (Harness Project Run)) ->
    Either PlanError ()
wrongCandidateScope profile root spec config =
    withRecoveredProductionProjectPlanInputs
        profile
        root
        spec
        config
        (\_spec _refined _drafts -> ())
