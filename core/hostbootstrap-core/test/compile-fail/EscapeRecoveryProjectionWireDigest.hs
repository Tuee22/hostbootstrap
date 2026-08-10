module EscapeRecoveryProjectionWireDigest where

import Data.ByteString (ByteString)
import HostBootstrap.Handoff

data CallerChosenRecoveryWireDigest

selectDigest ::
    RecoveryProjectionBinding
        scope broker verb plan parent child CallerChosenRecoveryWireDigest ->
    ()
selectDigest _ = ()

escapeDigest ::
    RootBroker scope broker verb ->
    RecoveryProjectionBindingInput plan parent child ->
    ByteString ->
    Either HandoffError ()
escapeDigest broker input wire =
    mkRecoveryProjectionBinding broker input wire selectDigest
