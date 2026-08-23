module ForgePlanExecutionPackage where

-- The canonical execution package is a Cabal-private carrier. Downstream code
-- receives only the opaque StepExecution facade and cannot construct, decode,
-- or replace its dedicated package slot.
import HostBootstrap.Lifecycle.Execution
    ( PlanExecutionPackage
    , mintPlanExecutionPackage
    )
