{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

module HostBootstrap.Lifecycle.Execution.Internal (
    ExecutionNode (..),
    PlanExecutionPackage,
    mintPlanExecutionPackage,
    planExecutionPackagePlanDigest,
    planExecutionPackageSpecDigest,
    planExecutionPackageConfigDigest,
    planExecutionPackageNodeIdentity,
    planExecutionPackageProfile,
    planExecutionPackageGeneration,
    planExecutionPackageProject,
    planExecutionPackageRoot,
    planExecutionPackageNode,
    StepExecution,
    mintStepExecution,
    stepExecutionHostConfig,
    stepExecutionPlanDigest,
    stepExecutionSpecDigest,
    stepExecutionConfigDigest,
    stepExecutionNodeIdentity,
    stepExecutionOperationKey,
    stepExecutionFrame,
    stepExecutionNode,
    stepExecutionRuntime,
    stepExecutionPackage,
    executionNodeDependencyKeys,

    -- * The per-node runtime the interpreter opens
    StepRuntime,
    newStepRuntime,
    setStepRuntimeOwnGate,
    stepRuntimeOwnGate,
    openStepRuntimeGate,
    stepRuntimeOpenGates,
    stepRuntimeTakenGates,
    takeStepRuntimeGate,
    stepRuntimeCarrier,
    registerStepRuntimeDependencyPackage,
    stepRuntimeDependencyPackages,
    registerStepRuntimeDependencyService,
    replaceStepRuntimeDependencyService,
    invokeStepRuntimeDependencyService,
    replaceStepRuntimeActivationSigningService,
    invokeStepRuntimeActivationSigningService,

    -- * The in-process carrier for managed handles
    ResourceCarrier,
    newResourceCarrier,
    CarriedResource,
    mintTransferredCarriedResource,
    mintSettledCarriedResource,
    carriedResourceKey,
    carriedResourceGeneration,
    carriedResourceObservationVersion,
    carriedResourceOwnershipOperation,
    carriedResourceSettlement,
    pushCarriedResource,
    readCarriedResources,
) where

import Data.ByteString (ByteString)
import Data.IORef (atomicModifyIORef', readIORef)
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Dependency.Internal (
    RuntimeDependencyPackage,
    runtimeDependencyPackageCommitment,
    runtimeDependencyPackageKey,
    runtimeDependencyPackageRoute,
 )
import HostBootstrap.Lifecycle.Execution.Core (
    CarriedResource,
    ResourceCarrierCore,
    StepRuntimeCore,
    carriedResourceGeneration,
    carriedResourceKey,
    carriedResourceObservationVersion,
    carriedResourceOwnershipOperation,
    carriedResourceSettlement,
    mintSettledCarriedResource,
    mintTransferredCarriedResource,
    resourceCarrierCoreRefs,
    stepRuntimeCoreRefs,
 )
import qualified HostBootstrap.Lifecycle.Execution.Core as Core (
    newResourceCarrierCore,
    newStepRuntimeCore,
    pushCarriedResource,
    readCarriedResources,
 )
import HostBootstrap.Lifecycle.Prepared.Internal (PreparedGate, preparedGateOperation)

{- | A neutral view of one validated plan node.

It deliberately contains no 'HostBootstrap.Step.Step' callback and no
'HostBootstrap.Reconcile' value.  Trusted lifecycle interpreters build this
view from an exact validated plan; reconciliation may then inspect it without
creating a @Step <-> Reconcile@ module cycle.

This module is hidden by the Cabal package.  In particular, downstream
projects cannot construct an 'ExecutionNode' and use it to mint plan authority.
-}
data ExecutionNode = ExecutionNode
    { executionNodeOperationKey :: Text
    , executionNodeFrame :: Text
    , executionNodeDependencies :: [(Text, Text)]
    {- ^ This node's exact ordered plan prefix, each member as its operation key
    paired with the frame the plan placed it in.  The frame travels with the
    key because a node that adopts a dependency's resource must name the same
    planned resource the plan did, and a planned resource is keyed by frame.
    -}
    , executionNodeProjectedKeys :: [Text]
    {- ^ The operations this node projects: keys the plan validated as living
    under this node's own key.  A relating resource's key is a projection of
    the keys it relates and is therefore nobody's own key, so this is the
    only route by which a node can reach one.
    -}
    , executionNodeChartWorkload :: Maybe (Text, Text, Text, Text, Text, Text, Text, Text, Text, [Text], Text)
    }
    deriving (Eq, Show)

executionNodeDependencyKeys :: ExecutionNode -> [Text]
executionNodeDependencyKeys = map fst . executionNodeDependencies

{- | Canonical, backend-neutral metadata projected from one exact admitted plan
for one executing node. The nominal indices bind it to that plan and scope;
the value contains no callback, backend witness, mutable gate, or carried
resource.
-}
data PlanExecutionPackage scope planId
    = PlanExecutionPackage
        Text
        Text
        Text
        Text
        Text
        Word64
        Text
        FilePath
        ExecutionNode
    deriving (Eq, Show)

type role PlanExecutionPackage nominal nominal

mintPlanExecutionPackage ::
    Text -> Text -> Text -> Text -> Text -> Word64 -> Text -> FilePath -> ExecutionNode -> PlanExecutionPackage scope planId
mintPlanExecutionPackage = PlanExecutionPackage

planExecutionPackageSpecDigest :: PlanExecutionPackage scope planId -> Text
planExecutionPackageSpecDigest (PlanExecutionPackage value _ _ _ _ _ _ _ _) = value

planExecutionPackagePlanDigest :: PlanExecutionPackage scope planId -> Text
planExecutionPackagePlanDigest (PlanExecutionPackage _ value _ _ _ _ _ _ _) = value

planExecutionPackageConfigDigest :: PlanExecutionPackage scope planId -> Text
planExecutionPackageConfigDigest (PlanExecutionPackage _ _ value _ _ _ _ _ _) = value

planExecutionPackageNodeIdentity :: PlanExecutionPackage scope planId -> Text
planExecutionPackageNodeIdentity (PlanExecutionPackage _ _ _ value _ _ _ _ _) = value

planExecutionPackageProfile :: PlanExecutionPackage scope planId -> Text
planExecutionPackageProfile (PlanExecutionPackage _ _ _ _ value _ _ _ _) = value

planExecutionPackageGeneration :: PlanExecutionPackage scope planId -> Word64
planExecutionPackageGeneration (PlanExecutionPackage _ _ _ _ _ value _ _ _) = value

planExecutionPackageProject :: PlanExecutionPackage scope planId -> Text
planExecutionPackageProject (PlanExecutionPackage _ _ _ _ _ _ value _ _) = value

planExecutionPackageRoot :: PlanExecutionPackage scope planId -> FilePath
planExecutionPackageRoot (PlanExecutionPackage _ _ _ _ _ _ _ value _) = value

planExecutionPackageNode :: PlanExecutionPackage scope planId -> ExecutionNode
planExecutionPackageNode (PlanExecutionPackage _ _ _ _ _ _ _ _ value) = value

{- | Plan-minted authority to execute one exact step.

The @scope@ and @planId@ indices bind the descriptor to the lifecycle plan that
minted it.  Its constructor stays private even inside the package: trusted
interpreters use 'mintStepExecution', while project callbacks receive only the
opaque public type from "HostBootstrap.Lifecycle.Execution".
-}
data StepExecution scope planId
    = StepExecution
        HostConfig
        (PlanExecutionPackage scope planId)
        (StepRuntime scope planId)

type role StepExecution nominal nominal

{- | Package-internal minting seam.  The node is a neutral view derived from the
exact validated lifecycle plan, and it already carries that node's ordered edge
set and projected operations, so the descriptor holds exactly one copy of them.

The runtime is the interpreter's own per-node state: the gates it opened for
this node's projections and the interpretation-wide carrier of managed handles.
It is mutable because a gate can only be opened inside an exclusive protected
entry, which is a strictly later moment than the pure mint.
-}
mintStepExecution ::
    HostConfig ->
    PlanExecutionPackage scope planId ->
    StepRuntime scope planId ->
    StepExecution scope planId
mintStepExecution = StepExecution

stepExecutionHostConfig :: StepExecution scope planId -> HostConfig
stepExecutionHostConfig (StepExecution cfg _ _) = cfg

stepExecutionPlanDigest :: StepExecution scope planId -> Text
stepExecutionPlanDigest (StepExecution _ package _) = planExecutionPackagePlanDigest package

stepExecutionSpecDigest :: StepExecution scope planId -> Text
stepExecutionSpecDigest (StepExecution _ package _) = planExecutionPackageSpecDigest package

-- | The stable digest of the exact configuration admitted with the plan.
stepExecutionConfigDigest :: StepExecution scope planId -> Text
stepExecutionConfigDigest (StepExecution _ package _) = planExecutionPackageConfigDigest package

{- | Reporting view of the exact stable node identity retained by the plan.

The identity is rendered before it enters this module so the execution kernel
does not import "HostBootstrap.Step" and create a @Step -> Execution -> Step@
module cycle. It is never parsed back into authority.
-}
stepExecutionNodeIdentity :: StepExecution scope planId -> Text
stepExecutionNodeIdentity (StepExecution _ package _) = planExecutionPackageNodeIdentity package

stepExecutionOperationKey :: StepExecution scope planId -> Text
stepExecutionOperationKey = executionNodeOperationKey . stepExecutionNode

stepExecutionFrame :: StepExecution scope planId -> Text
stepExecutionFrame = executionNodeFrame . stepExecutionNode

-- | Package-internal view of the descriptor's exact current node.
stepExecutionNode :: StepExecution scope planId -> ExecutionNode
stepExecutionNode (StepExecution _ package _) = planExecutionPackageNode package

-- | Package-internal view of the interpreter state behind the descriptor.
stepExecutionRuntime :: StepExecution scope planId -> StepRuntime scope planId
stepExecutionRuntime (StepExecution _ _ runtime) = runtime

stepExecutionPackage :: StepExecution scope planId -> PlanExecutionPackage scope planId
stepExecutionPackage (StepExecution _ package _) = package

-- ---------------------------------------------------------------------------
-- The per-node runtime

{- | What the interpreter opened for one node, and what the interpretation is
carrying between nodes.

The node's own gate is held apart from its projections. A successful callback
settles the own gate and only the projections the action took. A synchronous
exception or returned non-success observation terminalizes the own gate and
every projection opened for this node, including untaken gates.
The two projection 'IORef's track available and taken gates; a take moves a gate
between them exactly once, letting the interpreter apply the appropriate
settlement policy to each callback outcome.
-}
type StepRuntime scope planId =
    StepRuntimeCore scope planId PreparedGate (RuntimeDependencyPackage scope planId)

-- | Open an empty runtime over the interpretation's carrier.
newStepRuntime :: ResourceCarrier scope planId -> IO (StepRuntime scope planId)
newStepRuntime = Core.newStepRuntimeCore

{- | Record the gate the interpreter opened for this node's own operation.
Package-internal: its only caller is the chain interpreter, inside the exclusive
entry that published the node's unknown phase.
-}
setStepRuntimeOwnGate :: StepRuntime scope planId -> PreparedGate -> IO ()
setStepRuntimeOwnGate runtime gate =
    case stepRuntimeCoreRefs runtime of
        (own, _, _, _) -> atomicModifyIORef' own (\_ -> (Just gate, ()))

{- | The gate for this node's own operation, if the interpreter has opened it.

Unlike a projection this is read rather than taken: the interpreter settles the
node's own operation from the same gate once the action returns, so handing it
out does not transfer responsibility for it.
-}
stepRuntimeOwnGate :: StepRuntime scope planId -> IO (Maybe PreparedGate)
stepRuntimeOwnGate runtime =
    case stepRuntimeCoreRefs runtime of
        (own, _, _, _) -> readIORef own

{- | Record a gate the interpreter opened for one of this node's projections.
Package-internal: the only caller is the chain interpreter, which reads the keys
off the validated plan.
-}
openStepRuntimeGate :: StepRuntime scope planId -> PreparedGate -> IO ()
openStepRuntimeGate runtime gate =
    case stepRuntimeCoreRefs runtime of
        (_, available, _, _) -> atomicModifyIORef' available (\gates -> (gates ++ [gate], ()))

-- | The gates still available to this node's action.
stepRuntimeOpenGates :: StepRuntime scope planId -> IO [PreparedGate]
stepRuntimeOpenGates runtime =
    case stepRuntimeCoreRefs runtime of
        (_, available, _, _) -> readIORef available

{- | The gates this node's action took, in the order it took them.  The
interpreter settles exactly these with the node.
-}
stepRuntimeTakenGates :: StepRuntime scope planId -> IO [PreparedGate]
stepRuntimeTakenGates runtime =
    case stepRuntimeCoreRefs runtime of
        (_, _, taken, _) -> readIORef taken

{- | Hand out the gate for one projected operation, at most once.

'Nothing' means the node has no such gate available — either it never declared
the projection, or the gate has already been taken.  A prepared call authorises
exactly one effect, so a second take would run two effects behind one durable
unknown record.
-}
takeStepRuntimeGate :: StepRuntime scope planId -> Text -> IO (Maybe PreparedGate)
takeStepRuntimeGate runtime key =
    case stepRuntimeCoreRefs runtime of
        (_, available, taken, _) -> do
            picked <-
                atomicModifyIORef'
                    available
                    ( \gates -> case break ((== key) . preparedGateOperation) gates of
                        (before, gate : after) -> (before ++ after, Just gate)
                        (_, []) -> (gates, Nothing)
                    )
            case picked of
                Nothing -> pure Nothing
                Just gate -> do
                    atomicModifyIORef' taken (\gates -> (gates ++ [gate], ()))
                    pure (Just gate)

stepRuntimeCarrier :: StepRuntime scope planId -> ResourceCarrier scope planId
stepRuntimeCarrier runtime =
    case stepRuntimeCoreRefs runtime of
        (_, _, _, carrier) -> carrier

{- | Register one canonical dependency commitment in the invocation-wide
registry. Exact retries converge; a different package under the same closed
domain/resource key refuses rather than replacing recovery identity.
-}
registerStepRuntimeDependencyPackage ::
    StepRuntime scope planId ->
    RuntimeDependencyPackage scope planId ->
    IO (Either Text ())
registerStepRuntimeDependencyPackage runtime package =
    let (_, packages, _, _) = resourceCarrierCoreRefs (stepRuntimeCarrier runtime)
     in atomicModifyIORef' packages $ \current ->
            case filter ((== runtimeDependencyPackageKey package) . runtimeDependencyPackageKey) current of
                [] -> (current ++ [package], Right ())
                [existing]
                    | existing == package -> (current, Right ())
                    | otherwise -> (current, Left "runtime dependency key already names another canonical package")
                _ -> (current, Left "runtime dependency registry contains a duplicate canonical key")

stepRuntimeDependencyPackages :: StepRuntime scope planId -> IO [RuntimeDependencyPackage scope planId]
stepRuntimeDependencyPackages runtime =
    let (_, packages, _, _) = resourceCarrierCoreRefs (stepRuntimeCarrier runtime)
     in readIORef packages

-- | Retain the first live closure for an exact package and route. In particular,
-- exact registration cannot discard nonce consumption captured by that closure.
registerStepRuntimeDependencyService ::
    StepRuntime scope planId ->
    RuntimeDependencyPackage scope planId ->
    (ByteString -> IO (Either Text ByteString)) ->
    IO (Either Text ())
registerStepRuntimeDependencyService runtime package service = do
    let (_, packages, services, _) = resourceCarrierCoreRefs (stepRuntimeCarrier runtime)
        route = runtimeDependencyPackageRoute package
        commitment = runtimeDependencyPackageCommitment package
    canonical <- readIORef packages
    if package `notElem` canonical
        then pure (Left "runtime dependency live service has no exact canonical package")
        else atomicModifyIORef' services $ \current ->
            case [(observed, retained) | (existing, observed, retained) <- current, existing == route] of
                [] -> (current ++ [(route, commitment, service)], Right ())
                [(observed, _)]
                    | observed == commitment -> (current, Right ())
                    | otherwise -> (current, Left "runtime dependency live route names another canonical package")
                _ -> (current, Left "runtime dependency live route is duplicated")

{- | Install or replace the live closure for one already-registered exact
package. The closure is held only in the separate live tuple and is never a
field of the canonical package.
-}
replaceStepRuntimeDependencyService ::
    StepRuntime scope planId ->
    RuntimeDependencyPackage scope planId ->
    (ByteString -> IO (Either Text ByteString)) ->
    IO (Either Text ())
replaceStepRuntimeDependencyService runtime package service = do
    let (_, packages, services, _) = resourceCarrierCoreRefs (stepRuntimeCarrier runtime)
        route = runtimeDependencyPackageRoute package
        commitment = runtimeDependencyPackageCommitment package
    canonical <- readIORef packages
    if package `notElem` canonical
        then pure (Left "runtime dependency live service has no exact canonical package")
        else do
            atomicModifyIORef'
                services
                (\current -> (filter (\(existingRoute, _, _) -> existingRoute /= route) current ++ [(route, commitment, service)], ()))
            pure (Right ())

{- | Invoke the separately retained live closure only after the exact package,
route, and canonical commitment all match. A refusal returns before the closure
is evaluated.
-}
invokeStepRuntimeDependencyService ::
    StepRuntime scope planId ->
    RuntimeDependencyPackage scope planId ->
    ByteString ->
    IO (Either Text ByteString)
invokeStepRuntimeDependencyService runtime package request = do
    let (_, packages, services, _) = resourceCarrierCoreRefs (stepRuntimeCarrier runtime)
        route = runtimeDependencyPackageRoute package
        commitment = runtimeDependencyPackageCommitment package
    canonical <- readIORef packages
    live <- readIORef services
    if package `notElem` canonical
        then pure (Left "runtime dependency probe has no exact canonical package")
        else case [(observedCommitment, service) | (observedRoute, observedCommitment, service) <- live, observedRoute == route] of
            [(observedCommitment, service)]
                | observedCommitment == commitment -> service request
                | otherwise -> pure (Left "runtime dependency live commitment mismatch")
            [] -> pure (Left "runtime dependency live service is absent")
            _ -> pure (Left "runtime dependency live route is duplicated")

-- | Install the one invocation-local route to the admitted root activation signer.
replaceStepRuntimeActivationSigningService ::
    StepRuntime scope planId ->
    (ByteString -> IO (Either Text ByteString)) ->
    IO ()
replaceStepRuntimeActivationSigningService runtime service =
    let (_, _, _, activation) = resourceCarrierCoreRefs (stepRuntimeCarrier runtime)
     in atomicModifyIORef' activation (const (Just service, ()))

-- | Ask the admitted root to sign one canonical activation manifest.
invokeStepRuntimeActivationSigningService ::
    StepRuntime scope planId ->
    ByteString ->
    IO (Either Text ByteString)
invokeStepRuntimeActivationSigningService runtime request = do
    let (_, _, _, activation) = resourceCarrierCoreRefs (stepRuntimeCarrier runtime)
    service <- readIORef activation
    maybe (pure (Left "runtime activation signing service is absent")) ($ request) service

-- ---------------------------------------------------------------------------
-- The in-process carrier

{- | One exact interpretation's shared carrier, specialized to this unit's
canonical dependency package. Registry and service validation stay above the
primitive shared representation.
-}
type ResourceCarrier scope planId =
    ResourceCarrierCore scope planId (RuntimeDependencyPackage scope planId)

-- | Allocate the shared carrier for trusted interpreter entry points.
newResourceCarrier :: IO (ResourceCarrier scope planId)
newResourceCarrier = Core.newResourceCarrierCore

pushCarriedResource :: ResourceCarrier scope planId -> CarriedResource -> IO ()
pushCarriedResource = Core.pushCarriedResource

readCarriedResources :: ResourceCarrier scope planId -> IO [CarriedResource]
readCarriedResources = Core.readCarriedResources
