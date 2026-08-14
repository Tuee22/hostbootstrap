module OpenTeardownForestWithLifecyclePlan where

import HostBootstrap.Authority (VerbDown)
import HostBootstrap.Reconcile (LifecyclePlan)
import HostBootstrap.Teardown

data Scope
data Plan
data Frame

-- The projection already carries its exact plan identity. Restoring the old
-- second plan argument must fail rather than create a ceremonial binding.
openWithSecondPlan ::
    LifecyclePlan Scope Plan ->
    TeardownPlan Scope Plan Frame VerbDown ->
    Either TeardownError (TeardownForest Scope Plan Frame VerbDown)
openWithSecondPlan = openTeardownForest
