module OpenFinalizedForwardChildProjector where

-- The public construction facade exposes the finalized specification only
-- abstractly and does not expose its retained projector or hidden eliminator.
import HostBootstrap.ProjectPlan.Construct
    ( FinalizedProjectSpec (FinalizedProjectSpec)
    , withFinalizedForwardChildProjectionKernel
    )
