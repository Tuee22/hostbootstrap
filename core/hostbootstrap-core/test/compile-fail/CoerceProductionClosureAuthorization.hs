module CoerceProductionClosureAuthorization where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (ProductionClosureAuthorization)

data FirstGeneration
data SecondGeneration

substitute :: ProductionClosureAuthorization project FirstGeneration -> ProductionClosureAuthorization project SecondGeneration
substitute = coerce
