module RecoveryGrantWrongVerbJoin where

import HostBootstrap.Authority (ProjectVerb (ProjectDown), VerbDestroy, VerbDown)
import HostBootstrap.Handoff

-- A recovery grant minted for destroy cannot be joined under a down verb,
-- even when the projection has the down index expected by the call.
joinDestroyGrantAsDown ::
    RecoveryProjectionBinding
        scope
        brokerGeneration
        VerbDown
        plan
        parent
        child
        wireDigest ->
    RecoveryWireGrant
        scope
        brokerGeneration
        VerbDestroy
        plan
        parent
        child
        wireDigest ->
    VerifiedHandoff scope brokerGeneration ->
    Either HandoffError ()
joinDestroyGrantAsDown projection grant handoff =
    withVerifiedRecoveryHandoff
        (ProjectDown :: ProjectVerb VerbDown)
        projection
        grant
        handoff
        (const ())
