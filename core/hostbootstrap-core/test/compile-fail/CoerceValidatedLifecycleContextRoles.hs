module CoerceValidatedLifecycleContextRoles where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Context (ValidatedLifecycleContext)

data ScopeA
data ScopeB
data SpecificationA
data SpecificationB
data PlanA
data PlanB
data ConfigurationA
data ConfigurationB
data FrameA
data FrameB

coerceScope ::
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationA FrameA ->
    ValidatedLifecycleContext ScopeB SpecificationA PlanA ConfigurationA FrameA
coerceScope = coerce

coerceSpecification ::
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationA FrameA ->
    ValidatedLifecycleContext ScopeA SpecificationB PlanA ConfigurationA FrameA
coerceSpecification = coerce

coercePlan ::
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationA FrameA ->
    ValidatedLifecycleContext ScopeA SpecificationA PlanB ConfigurationA FrameA
coercePlan = coerce

coerceConfiguration ::
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationA FrameA ->
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationB FrameA
coerceConfiguration = coerce

coerceFrame ::
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationA FrameA ->
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationA FrameB
coerceFrame = coerce
