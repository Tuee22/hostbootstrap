{- | Opaque, plan-indexed authority for one lifecycle-step execution.

A project step receives a 'StepExecution' only from the trusted chain
interpreter.  The descriptor carries the host-tool configuration needed by an
ordinary action together with the exact plan, operation, and frame identities
under which that action runs. It also retains reporting views of the admitted
configuration digest and stable node identity. Its nominal @scope@ and
@planId@ indices prevent values from distinct lifecycle plans being
cross-paired by typed consumers.

There is intentionally no public constructor or minting function.  The neutral
plan-node representation also remains package-internal, so a downstream project
cannot fabricate either a descriptor or the plan view from which one is minted.

The descriptor is also how a node reaches the operations __projected from__ it
(§ CC).  A relating resource's operation key is derived from the keys it
relates — the provider guest alias is @\<provider\>\/\<share\>\/guest-alias@ — so
it is nobody's own key and no node could otherwise prepare it.  A step declares
its projections in the plan, the interpreter opens a gate for each, and
'stepExecutionTakeProjectedGate' hands the node exactly those and no sibling's.
-}
module HostBootstrap.Lifecycle.Execution (
    StepExecution,
    stepExecutionHostConfig,
    stepExecutionPlanDigest,
    stepExecutionSpecDigest,
    stepExecutionConfigDigest,
    stepExecutionNodeIdentity,
    stepExecutionOperationKey,
    stepExecutionFrame,
    stepExecutionDependencyKeys,

    -- * The gates the interpreter opened for this node
    stepExecutionPreparedGate,
    stepExecutionProjectedOperations,
    stepExecutionTakeProjectedGate,

    -- * Interpreter state
    StepRuntime,
    newStepRuntime,
    ResourceCarrier,
    newResourceCarrier,
    carriedResourceKeys,
) where

import Data.Text (Text)
import HostBootstrap.Lifecycle.Execution.Internal (
    ResourceCarrier,
    StepExecution,
    StepRuntime,
    carriedResourceKey,
    executionNodeDependencyKeys,
    executionNodeProjectedKeys,
    newResourceCarrier,
    newStepRuntime,
    readCarriedResources,
    stepExecutionConfigDigest,
    stepExecutionFrame,
    stepExecutionHostConfig,
    stepExecutionNode,
    stepExecutionNodeIdentity,
    stepExecutionOperationKey,
    stepExecutionPlanDigest,
    stepExecutionSpecDigest,
    stepExecutionRuntime,
    stepRuntimeOwnGate,
    takeStepRuntimeGate,
 )
import HostBootstrap.Lifecycle.Prepared (PreparedGate)

{- | The operation keys of this step's exact ordered plan prefix.

Read off the step's own plan node, which is where the plan recorded them; a step
cannot select, extend, or reorder its own edge set. Reconciliation narrows this
to the resource-bearing members when it seals an @OperationPreconditionSet@
(§ CC) — that narrowing is the reconciler's, not the step's.
-}
stepExecutionDependencyKeys :: StepExecution scope planId -> [Text]
stepExecutionDependencyKeys = executionNodeDependencyKeys . stepExecutionNode

{- | The prepared gate for this node's __own__ operation.

The interpreter publishes the node's unknown phase before running its action, so
an adapter the action drives can prepare the node's own effect against the same
gate the interpreter will settle. It is read rather than taken: the node's own
operation settles with the node whether or not its action reached an adapter.

'Nothing' means this descriptor was minted outside an interpretation — there is
no journal behind it, so there is nothing to authorise.
-}
stepExecutionPreparedGate :: StepExecution scope planId -> IO (Maybe PreparedGate)
stepExecutionPreparedGate = stepRuntimeOwnGate . stepExecutionRuntime

{- | The operations this node projects, in declared order.

The plan validated each of them as living under this node's own operation key,
so this list is the exact set of operations beyond its own that the node may
reach.
-}
stepExecutionProjectedOperations :: StepExecution scope planId -> [Text]
stepExecutionProjectedOperations = executionNodeProjectedKeys . stepExecutionNode

{- | Take the prepared gate the interpreter opened for one of this node's
projected operations.

'Nothing' means this node may not reach that operation: the key is not one the
plan validated as a projection of this node, the interpreter opened no gate for
it, or the node has already taken it.  A prepared gate authorises exactly one
effect behind exactly one durable unknown record, so it is handed out once.

Taking a gate is also what tells the interpreter to settle that operation with
this node.  A projection whose gate is never taken stays unsettled and the
session refuses to close — the same rule the node's own operation obeys.
-}
stepExecutionTakeProjectedGate ::
    StepExecution scope planId ->
    Text ->
    IO (Maybe PreparedGate)
stepExecutionTakeProjectedGate execution key
    | key `notElem` stepExecutionProjectedOperations execution = pure Nothing
    | otherwise = takeStepRuntimeGate (stepExecutionRuntime execution) key

{- | The operation keys of the managed resources this interpretation is
carrying.  Reporting only: reading a carried resource back as a @Managed@ handle
is "HostBootstrap.Reconcile"'s, because only it can produce the ownership the
handle claims.
-}
carriedResourceKeys :: ResourceCarrier scope planId -> IO [Text]
carriedResourceKeys carrier = map carriedResourceKey <$> readCarriedResources carrier
