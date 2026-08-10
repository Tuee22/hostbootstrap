module EscapeProjectPlanIdentity where

import Data.List.NonEmpty (NonEmpty)
import HostBootstrap.Config.Schema (ValidatedConfig)
import HostBootstrap.Lifecycle.Mode (LifecycleProfile)
import HostBootstrap.ProjectPlan
    ( PlanDraft
    , PlanError
    , ProjectPlan
    )
import HostBootstrap.ProjectPlan.Construct (withProjectPlan)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)

data ChosenPlan

-- The fresh plan identity cannot escape the admission continuation under a
-- caller-selected name.
escapePlan ::
    LifecycleProfile scope ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    NonEmpty (PlanDraft scope specDigest (cfg scope)) ->
    Either PlanError (ProjectPlan scope specDigest ChosenPlan configId cfg)
escapePlan profile root config drafts =
    withProjectPlan profile root config drafts id
