module OpenPlannedForwardHandoff where

-- No public ProjectPlan facade exposes the planned-forward type, its hidden
-- constructor, its producer, or the narrow Process-input fold.
import HostBootstrap.ProjectPlan
    ( PlannedForwardHandoff (PlannedForwardHandoff)
    , withPlannedForwardHandoffKernel
    , withPlannedForwardProcessInputsKernel
    )
