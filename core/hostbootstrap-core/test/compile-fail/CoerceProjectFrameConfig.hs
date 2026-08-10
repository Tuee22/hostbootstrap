module CoerceProjectFrameConfig where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan.Frame (ProjectFrame)

data Scope
data SpecDigest
data PlanId
data ConfigA
data ConfigB
data Frame

wrongConfig ::
    ProjectFrame Scope SpecDigest PlanId ConfigA Frame ->
    ProjectFrame Scope SpecDigest PlanId ConfigB Frame
wrongConfig = coerce
