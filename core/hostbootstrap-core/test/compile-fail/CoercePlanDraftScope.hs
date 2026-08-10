module CoercePlanDraftScope where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan (PlanDraft)

data ScopeA
data ScopeB
data SpecDigest
data Config

wrongScope :: PlanDraft ScopeA SpecDigest Config -> PlanDraft ScopeB SpecDigest Config
wrongScope = coerce
