module CoerceTeardownPlanFrame where

import Data.Coerce (coerce)
import HostBootstrap.Authority (VerbDown)
import HostBootstrap.Teardown (TeardownPlan)

data Scope
data Plan
data FrameA
data FrameB

-- TeardownPlan's frame role is nominal, so representational coercion cannot
-- relabel a projection admitted for a different current frame.
coerceTeardownPlanFrame ::
    TeardownPlan Scope Plan FrameA VerbDown ->
    TeardownPlan Scope Plan FrameB VerbDown
coerceTeardownPlanFrame = coerce
