{- | Opaque, plan-indexed authority for one lifecycle-step execution.

A project step receives a 'StepExecution' only from the trusted chain
interpreter.  The descriptor carries the host-tool configuration needed by an
ordinary action together with the exact plan, operation, and frame identities
under which that action runs.  Its @scope@ and @planId@ indices prevent values
from distinct lifecycle plans being cross-paired by typed consumers.

There is intentionally no public constructor or minting function.  The neutral
plan-node representation also remains package-internal, so a downstream project
cannot fabricate either a descriptor or the plan view from which one is minted.
-}
module HostBootstrap.Lifecycle.Execution (
    StepExecution,
    stepExecutionHostConfig,
    stepExecutionPlanDigest,
    stepExecutionOperationKey,
    stepExecutionFrame,
) where

import HostBootstrap.Lifecycle.Execution.Internal (
    StepExecution,
    stepExecutionFrame,
    stepExecutionHostConfig,
    stepExecutionOperationKey,
    stepExecutionPlanDigest,
 )
