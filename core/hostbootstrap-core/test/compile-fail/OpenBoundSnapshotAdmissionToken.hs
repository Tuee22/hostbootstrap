module OpenBoundSnapshotAdmissionToken where

-- The lower existing-snapshot kernel is visible for the public facade, but its
-- package-private admission token must not be obtainable from this public
-- lifecycle module.
import HostBootstrap.Lifecycle.Mode
    ( existingBoundSnapshotAdmissionKernel
    , withBoundPlanSnapshotKernel
    )

lowerKernel = withBoundPlanSnapshotKernel existingBoundSnapshotAdmissionKernel
