module CoerceCurrentFrameIdentity where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan.Frame (ValidatedContext)

data Scope
data PlanId
data FrameA
data FrameB

wrongFrame ::
    ValidatedContext Scope PlanId FrameA ->
    ValidatedContext Scope PlanId FrameB
wrongFrame = coerce
