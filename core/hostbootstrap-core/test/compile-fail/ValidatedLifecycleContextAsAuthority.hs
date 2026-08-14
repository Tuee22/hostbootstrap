module ValidatedLifecycleContextAsAuthority where

import HostBootstrap.Authority
    ( CommandAuthority
    , ExecutePhase
    , VerbUp
    )
import HostBootstrap.Lifecycle.Context (ValidatedLifecycleContext)
import HostBootstrap.Lifecycle.Session
    ( AcquisitionJournal
    , LifecycleCursor
    )

data Scope
data Specification
data Plan
data Configuration
data Frame
data Broker

asJournal ::
    ValidatedLifecycleContext Scope Specification Plan Configuration Frame ->
    AcquisitionJournal Scope Plan Broker
asJournal value = value

asCursor ::
    ValidatedLifecycleContext Scope Specification Plan Configuration Frame ->
    LifecycleCursor Scope Plan Frame Broker VerbUp ExecutePhase
asCursor value = value

asCommand ::
    ValidatedLifecycleContext Scope Specification Plan Configuration Frame ->
    CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase
asCommand value = value
