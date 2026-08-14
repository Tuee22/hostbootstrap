module ImportProjectPlanProjectionInternal where

-- A downstream consumer cannot import the shared immediate-target projection
-- kernel that both the planned-forward package and the catalog delegate to.
import HostBootstrap.ProjectPlan.Projection.Internal
