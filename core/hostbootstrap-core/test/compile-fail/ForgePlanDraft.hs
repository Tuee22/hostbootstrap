module ForgePlanDraft where

import HostBootstrap.ProjectPlan (PlanDraft)

data Scope
data SpecDigest
data Config

-- A draft must be produced through a canonical root and validated configuration;
-- its opaque constructor is unavailable to callers.
forgedDraft :: PlanDraft Scope SpecDigest Config
forgedDraft = PlanDraft
