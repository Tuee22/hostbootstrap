module RawReverseInputsAsLifecycleEntry where

import HostBootstrap.Authority
    ( CommandAuthority
    , RootInvocationAuthority
    , TeardownPhase
    , VerbDown
    , VerbUp
    )
import HostBootstrap.Command (LifecycleEntry)
import HostBootstrap.Lifecycle.Mode (AcquisitionJournal, LifecycleCursor)

data Scope
data Plan
data Frame
data Broker
data SourcePlan
data SourceFrame
data SourceBroker

rootAsEntry ::
    RootInvocationAuthority Scope Broker VerbDown ->
    LifecycleEntry Scope Plan Frame Broker VerbDown
rootAsEntry raw = raw

sourceJournalAsEntry ::
    AcquisitionJournal Scope SourcePlan SourceBroker ->
    LifecycleEntry Scope Plan Frame Broker VerbDown
sourceJournalAsEntry raw = raw

sourceCursorAsEntry ::
    LifecycleCursor Scope SourcePlan SourceFrame SourceBroker VerbUp TeardownPhase ->
    LifecycleEntry Scope Plan Frame Broker VerbDown
sourceCursorAsEntry raw = raw

targetJournalAsEntry ::
    AcquisitionJournal Scope Plan Broker ->
    LifecycleEntry Scope Plan Frame Broker VerbDown
targetJournalAsEntry raw = raw

targetCursorAsEntry ::
    LifecycleCursor Scope Plan Frame Broker VerbDown TeardownPhase ->
    LifecycleEntry Scope Plan Frame Broker VerbDown
targetCursorAsEntry raw = raw

authorityAsEntry ::
    CommandAuthority Scope Plan Frame Broker VerbDown TeardownPhase ->
    LifecycleEntry Scope Plan Frame Broker VerbDown
authorityAsEntry raw = raw
