{-# LANGUAGE RoleAnnotations #-}

module HostBootstrap.Lifecycle.Execution.Internal (
    ExecutionNode (..),
    StepExecution,
    mintStepExecution,
    stepExecutionHostConfig,
    stepExecutionPlanDigest,
    stepExecutionConfigDigest,
    stepExecutionNodeIdentity,
    stepExecutionOperationKey,
    stepExecutionFrame,
    stepExecutionNode,
    stepExecutionRuntime,
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

    -- * The in-process carrier for managed handles
    ResourceCarrier,
    newResourceCarrier,
    CarriedResource,
    mintCarriedResource,
    carriedResourceKey,
    carriedResourceGeneration,
    carriedResourceObservationVersion,
    pushCarriedResource,
    readCarriedResources,
) where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.HostConfig (HostConfig)
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
    -- ^ This node's exact ordered plan prefix, each member as its operation key
    -- paired with the frame the plan placed it in.  The frame travels with the
    -- key because a node that adopts a dependency's resource must name the same
    -- planned resource the plan did, and a planned resource is keyed by frame.
    , executionNodeProjectedKeys :: [Text]
    -- ^ The operations this node projects: keys the plan validated as living
    -- under this node's own key.  A relating resource's key is a projection of
    -- the keys it relates and is therefore nobody's own key, so this is the
    -- only route by which a node can reach one.
    }
    deriving (Eq, Show)

executionNodeDependencyKeys :: ExecutionNode -> [Text]
executionNodeDependencyKeys = map fst . executionNodeDependencies

{- | Plan-minted authority to execute one exact step.

The @scope@ and @planId@ indices bind the descriptor to the lifecycle plan that
minted it.  Its constructor stays private even inside the package: trusted
interpreters use 'mintStepExecution', while project callbacks receive only the
opaque public type from "HostBootstrap.Lifecycle.Execution".
-}
data StepExecution scope planId = StepExecution
    HostConfig
    Text
    Text
    Text
    ExecutionNode
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
    Text ->
    Text ->
    Text ->
    ExecutionNode ->
    StepRuntime scope planId ->
    StepExecution scope planId
mintStepExecution = StepExecution

stepExecutionHostConfig :: StepExecution scope planId -> HostConfig
stepExecutionHostConfig (StepExecution cfg _ _ _ _ _) = cfg

stepExecutionPlanDigest :: StepExecution scope planId -> Text
stepExecutionPlanDigest (StepExecution _ digest _ _ _ _) = digest

-- | The stable digest of the exact configuration admitted with the plan.
stepExecutionConfigDigest :: StepExecution scope planId -> Text
stepExecutionConfigDigest (StepExecution _ _ digest _ _ _) = digest

{- | Reporting view of the exact stable node identity retained by the plan.

The identity is rendered before it enters this module so the execution kernel
does not import "HostBootstrap.Step" and create a @Step -> Execution -> Step@
module cycle. It is never parsed back into authority.
-}
stepExecutionNodeIdentity :: StepExecution scope planId -> Text
stepExecutionNodeIdentity (StepExecution _ _ _ identity _ _) = identity

stepExecutionOperationKey :: StepExecution scope planId -> Text
stepExecutionOperationKey = executionNodeOperationKey . stepExecutionNode

stepExecutionFrame :: StepExecution scope planId -> Text
stepExecutionFrame = executionNodeFrame . stepExecutionNode

-- | Package-internal view of the descriptor's exact current node.
stepExecutionNode :: StepExecution scope planId -> ExecutionNode
stepExecutionNode (StepExecution _ _ _ _ node _) = node

-- | Package-internal view of the interpreter state behind the descriptor.
stepExecutionRuntime :: StepExecution scope planId -> StepRuntime scope planId
stepExecutionRuntime (StepExecution _ _ _ _ _ runtime) = runtime

-- ---------------------------------------------------------------------------
-- The per-node runtime

{- | What the interpreter opened for one node, and what the interpretation is
carrying between nodes.

The node's own gate is held apart from its projections' because the two are
consumed differently: the interpreter settles the node's own gate whether or not
the action used it, while a projection is settled only if the action took it.
The remaining two 'IORef's are the projections still available and the ones
already taken; a gate moves from the first to the second exactly once, which is
what lets the interpreter settle precisely the projections the node reached and
leave the rest unsettled.
-}
data StepRuntime scope planId
    = StepRuntime
        (IORef (Maybe PreparedGate))
        (IORef [PreparedGate])
        (IORef [PreparedGate])
        (ResourceCarrier scope planId)

type role StepRuntime nominal nominal

-- | Open an empty runtime over the interpretation's carrier.
newStepRuntime :: ResourceCarrier scope planId -> IO (StepRuntime scope planId)
newStepRuntime carrier = do
    own <- newIORef Nothing
    available <- newIORef []
    taken <- newIORef []
    pure (StepRuntime own available taken carrier)

{- | Record the gate the interpreter opened for this node's own operation.
Package-internal: its only caller is the chain interpreter, inside the exclusive
entry that published the node's unknown phase.
-}
setStepRuntimeOwnGate :: StepRuntime scope planId -> PreparedGate -> IO ()
setStepRuntimeOwnGate (StepRuntime own _ _ _) gate =
    atomicModifyIORef' own (\_ -> (Just gate, ()))

{- | The gate for this node's own operation, if the interpreter has opened it.

Unlike a projection this is read rather than taken: the interpreter settles the
node's own operation from the same gate once the action returns, so handing it
out does not transfer responsibility for it.
-}
stepRuntimeOwnGate :: StepRuntime scope planId -> IO (Maybe PreparedGate)
stepRuntimeOwnGate (StepRuntime own _ _ _) = readIORef own

{- | Record a gate the interpreter opened for one of this node's projections.
Package-internal: the only caller is the chain interpreter, which reads the keys
off the validated plan.
-}
openStepRuntimeGate :: StepRuntime scope planId -> PreparedGate -> IO ()
openStepRuntimeGate (StepRuntime _ available _ _) gate =
    atomicModifyIORef' available (\gates -> (gates ++ [gate], ()))

-- | The gates still available to this node's action.
stepRuntimeOpenGates :: StepRuntime scope planId -> IO [PreparedGate]
stepRuntimeOpenGates (StepRuntime _ available _ _) = readIORef available

{- | The gates this node's action took, in the order it took them.  The
interpreter settles exactly these with the node.
-}
stepRuntimeTakenGates :: StepRuntime scope planId -> IO [PreparedGate]
stepRuntimeTakenGates (StepRuntime _ _ taken _) = readIORef taken

{- | Hand out the gate for one projected operation, at most once.

'Nothing' means the node has no such gate available — either it never declared
the projection, or the gate has already been taken.  A prepared call authorises
exactly one effect, so a second take would run two effects behind one durable
unknown record.
-}
takeStepRuntimeGate :: StepRuntime scope planId -> Text -> IO (Maybe PreparedGate)
takeStepRuntimeGate (StepRuntime _ available taken _) key = do
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
stepRuntimeCarrier (StepRuntime _ _ _ carrier) = carrier

-- ---------------------------------------------------------------------------
-- The in-process carrier

{- | One managed resource identity, erased of the generative indices that made
it unforgeable.

The erased form never leaves the package: "HostBootstrap.Reconcile" is the only
module that mints one (from a @Managed@ handle it produced) and the only module
that reads one back (into a @Managed@ handle under fresh skolems).  A generative
handle is never serialised (§ EE), so this is how the node that acquires a
resource hands it to the node that depends on it — in process, inside one
interpretation.
-}
data CarriedResource = CarriedResource Text Word64 Word64
    deriving (Eq, Show)

mintCarriedResource :: Text -> Word64 -> Word64 -> CarriedResource
mintCarriedResource = CarriedResource

carriedResourceKey :: CarriedResource -> Text
carriedResourceKey (CarriedResource key _ _) = key

carriedResourceGeneration :: CarriedResource -> Word64
carriedResourceGeneration (CarriedResource _ generation _) = generation

carriedResourceObservationVersion :: CarriedResource -> Word64
carriedResourceObservationVersion (CarriedResource _ _ version) = version

{- | The managed resources one interpretation has acquired so far.

It is indexed by the plan's @scope@ and @planId@, so a handle carried under one
interpretation cannot be read out under another even though the erased form
carries no index of its own.
-}
newtype ResourceCarrier scope planId = ResourceCarrier (IORef [CarriedResource])

type role ResourceCarrier nominal nominal

newResourceCarrier :: IO (ResourceCarrier scope planId)
newResourceCarrier = ResourceCarrier <$> newIORef []

{- | Carry one managed resource, replacing any earlier entry under the same
operation key.  A node that re-runs mints a fresh handle for the same key, and
the dependency-snapshot traversal refuses a key it finds twice, so the newest
identity is the one that must be visible.
-}
pushCarriedResource :: ResourceCarrier scope planId -> CarriedResource -> IO ()
pushCarriedResource (ResourceCarrier entries) entry =
    atomicModifyIORef'
        entries
        ( \carried ->
            ( filter ((/= carriedResourceKey entry) . carriedResourceKey) carried ++ [entry]
            , ()
            )
        )

readCarriedResources :: ResourceCarrier scope planId -> IO [CarriedResource]
readCarriedResources (ResourceCarrier entries) = readIORef entries
