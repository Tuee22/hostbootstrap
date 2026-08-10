module CrossPlanCommandAuthority where

import Data.Coerce (coerce)
import HostBootstrap.Authority

data Scope
data PlanA
data PlanB
data Frame
data Epoch

wrongPlan ::
    CommandAuthority Scope PlanA Frame Epoch VerbUp ExecutePhase ->
    CommandAuthority Scope PlanB Frame Epoch VerbUp ExecutePhase
wrongPlan = coerce
