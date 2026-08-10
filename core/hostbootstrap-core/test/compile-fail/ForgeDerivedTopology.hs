module ForgeDerivedTopology where

import HostBootstrap.ProjectPlan (DerivedTopology)

data Scope
data PlanId

forged :: DerivedTopology Scope PlanId
forged = DerivedTopology
