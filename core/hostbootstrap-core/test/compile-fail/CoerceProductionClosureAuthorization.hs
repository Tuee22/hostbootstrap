module CoerceProductionClosureAuthorization where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (ProductionClosureAuthorization)

data FirstProject
data SecondProject
data FirstGeneration
data SecondGeneration

substituteGeneration ::
    ProductionClosureAuthorization FirstProject FirstGeneration ->
    ProductionClosureAuthorization FirstProject SecondGeneration
substituteGeneration = coerce

substituteProject ::
    ProductionClosureAuthorization FirstProject FirstGeneration ->
    ProductionClosureAuthorization SecondProject FirstGeneration
substituteProject = coerce
