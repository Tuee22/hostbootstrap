module AcquisitionJournalAsCommandAuthority where

import HostBootstrap.Authority
    ( CommandAuthority
    , ExecutePhase
    , VerbUp
    )
import HostBootstrap.Lifecycle.Mode (AcquisitionJournal)

data Scope
data PlanId
data Frame
data BrokerGeneration

consumeCommand ::
    CommandAuthority Scope PlanId Frame BrokerGeneration VerbUp ExecutePhase ->
    ()
consumeCommand _ = ()

-- The journal is descriptive acquisition evidence, not an effect authority.
journalCannotAuthorize :: AcquisitionJournal Scope PlanId BrokerGeneration -> ()
journalCannotAuthorize journal = consumeCommand journal
