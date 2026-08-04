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
    stepExecutionDependencyKeys,
) where

import Data.Text (Text)
import HostBootstrap.Lifecycle.Execution.Internal (
    StepExecution,
    executionNodeDependencyKeys,
    stepExecutionFrame,
    stepExecutionHostConfig,
    stepExecutionNode,
    stepExecutionOperationKey,
    stepExecutionPlanDigest,
 )

{- | The operation keys of this step's exact ordered plan prefix.

Read off the step's own plan node, which is where the plan recorded them; a step
cannot select, extend, or reorder its own edge set. Reconciliation narrows this
to the resource-bearing members when it seals an @OperationPreconditionSet@
(§ CC) — that narrowing is the reconciler's, not the step's.
-}
stepExecutionDependencyKeys :: StepExecution scope planId -> [Text]
stepExecutionDependencyKeys = executionNodeDependencyKeys . stepExecutionNode
