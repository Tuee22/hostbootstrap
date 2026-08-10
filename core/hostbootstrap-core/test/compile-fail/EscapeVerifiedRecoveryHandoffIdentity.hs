module EscapeVerifiedRecoveryHandoffIdentity where

import HostBootstrap.Authority (ProjectVerb)
import HostBootstrap.Handoff

data CallerChosenVerifiedRecoveryHandoff

selectHandoff ::
    VerifiedRecoveryHandoff
        scope broker plan parent child digest CallerChosenVerifiedRecoveryHandoff verb ->
    ()
selectHandoff _ = ()

escapeHandoff ::
    ProjectVerb verb ->
    RecoveryProjectionBinding scope broker verb plan parent child digest ->
    RecoveryWireGrant scope broker verb plan parent child digest ->
    VerifiedHandoff scope broker ->
    Either HandoffError ()
escapeHandoff verb binding grant handoff =
    withVerifiedRecoveryHandoff verb binding grant handoff selectHandoff
