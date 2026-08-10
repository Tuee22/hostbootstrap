module EscapeVerifiedRecoveryWireIdentity where

import Data.ByteString (ByteString)
import HostBootstrap.Handoff

data CallerChosenVerifiedRecoveryWire

selectWire ::
    VerifiedRecoveryWire
        scope broker verb plan child digest CallerChosenVerifiedRecoveryWire ->
    ()
selectWire _ = ()

escapeWire ::
    ProjectVerificationKey ->
    RecoveryProjectionBinding scope broker verb plan parent child digest ->
    ByteString ->
    RecoveryWireGrant scope broker verb plan parent child digest ->
    Either HandoffError ()
escapeWire key binding wire grant =
    withVerifiedRecoveryWire key binding wire grant selectWire
