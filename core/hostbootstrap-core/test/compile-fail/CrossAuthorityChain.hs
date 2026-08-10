module CrossAuthorityChain where

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
data AuthorityPlan
data Configuration
data Config scope
data Frame
data AuthorityFrame
data Broker
data AuthorityBroker

wrongScope ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority ForeignScope Plan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope Plan Frame Broker VerbUp ExecutePhase ->
    ()
wrongScope cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()

wrongPlan ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope AuthorityPlan Frame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope Plan Frame Broker VerbUp ExecutePhase ->
    ()
wrongPlan cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()

wrongFrame ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan AuthorityFrame Broker VerbUp ExecutePhase ->
    LifecycleCursor Scope Plan Frame Broker VerbUp ExecutePhase ->
    ()
wrongFrame cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()

wrongBroker ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame AuthorityBroker VerbUp ExecutePhase ->
    LifecycleCursor Scope Plan Frame Broker VerbUp ExecutePhase ->
    ()
wrongBroker cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()

wrongVerb ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbDown ExecutePhase ->
    LifecycleCursor Scope Plan Frame Broker VerbUp ExecutePhase ->
    ()
wrongVerb cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()

wrongPhase ::
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan Scope Specification Plan Configuration Config ->
    CommandAuthority Scope Plan Frame Broker VerbUp PreparePhase ->
    LifecycleCursor Scope Plan Frame Broker VerbUp ExecutePhase ->
    ()
wrongPhase cfg self store plan authority cursor =
    seq (runChainFromFrame cfg self store plan authority cursor) ()
