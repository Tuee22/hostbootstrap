module LifecycleEntryAsRawEvidence where

import HostBootstrap.Authority (CommandAuthority, ExecutePhase, VerbUp)
import HostBootstrap.Command (LifecycleEntry)
import HostBootstrap.Lifecycle.Mode (AcquisitionJournal, LifecycleCursor)

data Scope
data Plan
data Frame
data Broker

asAuthority :: LifecycleEntry Scope Plan Frame Broker VerbUp -> CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase
asAuthority entry = entry

asJournal :: LifecycleEntry Scope Plan Frame Broker VerbUp -> AcquisitionJournal Scope Plan Broker
asJournal entry = entry

asCursor :: LifecycleEntry Scope Plan Frame Broker VerbUp -> LifecycleCursor Scope Plan Frame Broker VerbUp ExecutePhase
asCursor entry = entry
