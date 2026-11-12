module CrossCursorChain where

import HostBootstrap.Authority (
    CommandAuthority,
    ExecutePhase,
    PreparePhase,
    VerbDown,
    VerbUp,
 )
import HostBootstrap.Chain (runChainFromFrameWithDescentFailure)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Mode (LifecycleCursor)
import HostBootstrap.Lift (SelfRef)
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.Protected (ProtectedStore)

data Scope
data ForeignScope
data Specification
data Plan
data CursorPlan
data Configuration
data Config scope
data Frame
data CursorFrame
data Broker
data CursorBroker

wrongScope ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor ForeignScope Plan Frame Broker VerbUp ExecutePhase ->
    ()
wrongScope cfg self store plan authority cursor =
    seq (runChainFromFrameWithDescentFailure cfg self store plan authority cursor (\_ _ _ _ -> pure (Right ()))) ()

wrongPlan ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope CursorPlan Frame Broker VerbUp ExecutePhase ->
    ()
wrongPlan cfg self store plan authority cursor =
    seq (runChainFromFrameWithDescentFailure cfg self store plan authority cursor (\_ _ _ _ -> pure (Right ()))) ()

wrongFrame ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope Plan CursorFrame Broker VerbUp ExecutePhase ->
    ()
wrongFrame cfg self store plan authority cursor =
    seq (runChainFromFrameWithDescentFailure cfg self store plan authority cursor (\_ _ _ _ -> pure (Right ()))) ()

wrongBroker ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope Plan Frame CursorBroker VerbUp ExecutePhase ->
    ()
wrongBroker cfg self store plan authority cursor =
    seq (runChainFromFrameWithDescentFailure cfg self store plan authority cursor (\_ _ _ _ -> pure (Right ()))) ()

wrongVerb ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope Plan Frame Broker VerbDown ExecutePhase ->
    ()
wrongVerb cfg self store plan authority cursor =
    seq (runChainFromFrameWithDescentFailure cfg self store plan authority cursor (\_ _ _ _ -> pure (Right ()))) ()

wrongPhase ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope Plan Frame Broker VerbUp PreparePhase ->
    ()
wrongPhase cfg self store plan authority cursor =
    seq (runChainFromFrameWithDescentFailure cfg self store plan authority cursor (\_ _ _ _ -> pure (Right ()))) ()
