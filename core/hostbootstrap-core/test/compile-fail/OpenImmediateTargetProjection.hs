module OpenImmediateTargetProjection where

-- No public ProjectPlan facade exposes the shared VLC-free projection kernel,
-- so a caller cannot project or admit a target plan outside the planned-forward
-- package and the root-owned catalog.
import HostBootstrap.ProjectPlan (withImmediateTargetKernel)
