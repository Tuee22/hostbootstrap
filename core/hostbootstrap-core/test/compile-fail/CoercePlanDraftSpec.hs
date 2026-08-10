module CoercePlanDraftSpec where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan (PlanDraft)

data Scope
data SpecA
data SpecB
data Config

wrongSpecification :: PlanDraft Scope SpecA Config -> PlanDraft Scope SpecB Config
wrongSpecification = coerce
