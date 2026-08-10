module ForgePlanDraft where

import HostBootstrap.ProjectPlan (PlanDraft)

data Scope
data SpecDigest
data Config

-- A draft can be minted only from the exact canonical root and validated
-- configuration supplied to the finalized builder seam.
forgedDraft :: PlanDraft Scope SpecDigest Config
forgedDraft = PlanDraft
