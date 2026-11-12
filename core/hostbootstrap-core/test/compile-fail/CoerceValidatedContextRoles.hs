module CoerceValidatedContextRoles where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan.Frame (ValidatedContext)

-- Equal representations isolate the admitted context's three nominal roles.
newtype ContextScopeA = ContextScopeA ()
newtype ContextScopeB = ContextScopeB ()
newtype ContextPlanA = ContextPlanA ()
newtype ContextPlanB = ContextPlanB ()
newtype ContextFrameA = ContextFrameA ()
newtype ContextFrameB = ContextFrameB ()

coerceContextScope ::
    ValidatedContext ContextScopeA ContextPlanA ContextFrameA ->
    ValidatedContext ContextScopeB ContextPlanA ContextFrameA
coerceContextScope = coerce

coerceContextPlan ::
    ValidatedContext ContextScopeA ContextPlanA ContextFrameA ->
    ValidatedContext ContextScopeA ContextPlanB ContextFrameA
coerceContextPlan = coerce

coerceContextFrame ::
    ValidatedContext ContextScopeA ContextPlanA ContextFrameA ->
    ValidatedContext ContextScopeA ContextPlanA ContextFrameB
coerceContextFrame = coerce
