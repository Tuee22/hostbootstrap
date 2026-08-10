module CoerceBuildCoordinatorIdentity where

import Data.Coerce (coerce)
import HostBootstrap.Build (BuildCoordinator)

data CoordinatorA
data CoordinatorB

wrongCoordinator ::
    BuildCoordinator CoordinatorA ->
    BuildCoordinator CoordinatorB
wrongCoordinator = coerce
