module ImportProjectPlanHandoffInternal where

-- A downstream consumer cannot import the exact planned-forward package,
-- its constructor, or either of its fixed-unit eliminators.
import HostBootstrap.ProjectPlan.Handoff.Internal
