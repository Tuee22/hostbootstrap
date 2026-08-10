module CoerceCurrentFramePlan where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)

data Scope
data PlanA
data PlanB
data Frame

wrongPlan ::
    CurrentFrame Scope PlanA Frame ->
    CurrentFrame Scope PlanB Frame
wrongPlan = coerce
