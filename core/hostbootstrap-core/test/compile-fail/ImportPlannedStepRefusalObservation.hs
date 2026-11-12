module ImportPlannedStepRefusalObservation where

import Data.Text (Text)
import HostBootstrap.ProjectPlan

retained ::
    PlannedStep scope planId configId config ->
    Text ->
    PlannedStepObservation scope planId configId
retained = HostBootstrap.ProjectPlan.plannedStepRefusalObservation
