module CrossValidatedLifecycleContextIndices where

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

crossScope ::
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationA FrameA ->
    ValidatedLifecycleContext ScopeB SpecificationA PlanA ConfigurationA FrameA
crossScope value = value

crossSpecification ::
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationA FrameA ->
    ValidatedLifecycleContext ScopeA SpecificationB PlanA ConfigurationA FrameA
crossSpecification value = value

crossPlan ::
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationA FrameA ->
    ValidatedLifecycleContext ScopeA SpecificationA PlanB ConfigurationA FrameA
crossPlan value = value

crossConfiguration ::
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationA FrameA ->
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationB FrameA
crossConfiguration value = value

crossFrame ::
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationA FrameA ->
    ValidatedLifecycleContext ScopeA SpecificationA PlanA ConfigurationA FrameB
crossFrame value = value
