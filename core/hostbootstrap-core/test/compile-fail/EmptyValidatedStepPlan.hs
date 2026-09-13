module EmptyValidatedStepPlan where

import Data.List.NonEmpty (NonEmpty)
import HostBootstrap.Step (Step, StepPlan, stepPlanSteps)

-- The plan constructor refuses an empty step list, and the accessor keeps that
-- fact: it answers with a non-empty sequence. A caller cannot read a plain list
-- out of a validated plan, so there is no empty branch on which to assert the
-- invariant a second time.
emptied :: StepPlan -> [Step]
emptied = stepPlanSteps

kept :: StepPlan -> NonEmpty Step
kept = stepPlanSteps
