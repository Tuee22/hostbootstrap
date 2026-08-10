module ReselectReturnedRecoveredProjectPlan where

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

data ChosenPlan

-- The returned ProjectPlan carries the existing planId. A caller cannot
-- re-label it with a selected identity in the result type.
reselectReturnedPlan ::
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
        (ProjectPlan (Production projectId) specDigest ChosenPlan configId cfg)
reselectReturnedPlan profile root verified snapshot binding config drafts =
    withRecoveredProductionProjectPlan
        profile
        root
        verified
        snapshot
        binding
        config
        drafts
        id
