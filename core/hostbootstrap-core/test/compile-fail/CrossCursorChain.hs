module CrossCursorChain where

import HostBootstrap.Authority
    ( CommandAuthority
    , ExecutePhase
    , PreparePhase
    , VerbDown
    , VerbUp
    )
import HostBootstrap.Chain (runChainFromFrame)
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
    seq (runChainFromFrame cfg self store plan authority cursor) ()

wrongPlan ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope CursorPlan Frame Broker VerbUp ExecutePhase ->
    ()
wrongPlan cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()

wrongFrame ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope Plan CursorFrame Broker VerbUp ExecutePhase ->
    ()
wrongFrame cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()

wrongBroker ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope Plan Frame CursorBroker VerbUp ExecutePhase ->
    ()
wrongBroker cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()

wrongVerb ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope Plan Frame Broker VerbDown ExecutePhase ->
    ()
wrongVerb cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()

wrongPhase ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope Plan Frame Broker VerbUp PreparePhase ->
    ()
wrongPhase cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()
