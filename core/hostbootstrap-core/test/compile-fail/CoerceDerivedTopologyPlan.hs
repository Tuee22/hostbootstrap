module CoerceDerivedTopologyPlan where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan (DerivedTopology)

data Scope
data PlanA
data PlanB

wrongPlan :: DerivedTopology Scope PlanA -> DerivedTopology Scope PlanB
wrongPlan = coerce
