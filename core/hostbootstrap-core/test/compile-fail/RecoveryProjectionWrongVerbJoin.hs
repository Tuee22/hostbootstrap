module RecoveryProjectionWrongVerbJoin where

import HostBootstrap.Authority (ProjectVerb (ProjectDown), VerbDestroy, VerbDown)
import HostBootstrap.Handoff

-- A projection minted for destroy cannot be joined under a down verb, even
-- when the grant has the down index expected by the call.
joinDestroyAsDown ::
    RecoveryProjectionBinding
        scope
        brokerGeneration
        VerbDestroy
        plan
        parent
        child
        wireDigest ->
    RecoveryWireGrant
        scope
        brokerGeneration
        VerbDown
        plan
        parent
        child
        wireDigest ->
    VerifiedHandoff scope brokerGeneration ->
    Either HandoffError ()
joinDestroyAsDown projection grant handoff =
    withVerifiedRecoveryHandoff
        (ProjectDown :: ProjectVerb VerbDown)
        projection
        grant
        handoff
        (const ())
