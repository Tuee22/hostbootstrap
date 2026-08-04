module HostBootstrap.Lifecycle.Execution.Internal (
    ExecutionNode (..),
    StepExecution,
    mintStepExecution,
    stepExecutionHostConfig,
    stepExecutionPlanDigest,
    stepExecutionOperationKey,
    stepExecutionFrame,
    stepExecutionNode,
) where

import Data.Text (Text)
import HostBootstrap.HostConfig (HostConfig)

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
    , executionNodeDependencyKeys :: [Text]
    }
    deriving (Eq, Show)

{- | Plan-minted authority to execute one exact step.

The @scope@ and @planId@ indices bind the descriptor to the lifecycle plan that
minted it.  Its constructor stays private even inside the package: trusted
interpreters use 'mintStepExecution', while project callbacks receive only the
opaque public type from "HostBootstrap.Lifecycle.Execution".
-}
data StepExecution scope planId = StepExecution
    HostConfig
    Text
    ExecutionNode

{- | Package-internal minting seam.  The node is a neutral view derived from the
exact validated lifecycle plan, and it already carries that node's ordered edge
set, so the descriptor holds exactly one copy of it.
-}
mintStepExecution ::
    HostConfig ->
    Text ->
    ExecutionNode ->
    StepExecution scope planId
mintStepExecution = StepExecution

stepExecutionHostConfig :: StepExecution scope planId -> HostConfig
stepExecutionHostConfig (StepExecution cfg _ _) = cfg

stepExecutionPlanDigest :: StepExecution scope planId -> Text
stepExecutionPlanDigest (StepExecution _ digest _) = digest

stepExecutionOperationKey :: StepExecution scope planId -> Text
stepExecutionOperationKey = executionNodeOperationKey . stepExecutionNode

stepExecutionFrame :: StepExecution scope planId -> Text
stepExecutionFrame = executionNodeFrame . stepExecutionNode

-- | Package-internal view of the descriptor's exact current node.
stepExecutionNode :: StepExecution scope planId -> ExecutionNode
stepExecutionNode (StepExecution _ _ node) = node
