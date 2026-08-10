module ForgePlannedStep where

import HostBootstrap.ProjectPlan (PlannedStep)

data Scope
data PlanId
data ConfigId
data Config

forged :: PlannedStep Scope PlanId ConfigId Config
forged = PlannedStep
