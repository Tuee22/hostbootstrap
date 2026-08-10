module ConfigGrantAsRecoveryGrant where

import Data.ByteString (ByteString)
import HostBootstrap.Handoff

-- The ordinary config-admission grant cannot be substituted for the distinct
-- recovery-wire grant, even when both values name the same scope.
verifyRecoveryWithConfigGrant ::
    ProjectVerificationKey ->
    RecoveryProjectionBinding scope brokerGeneration verb plan parent child wireDigest ->
    ByteString ->
    HandoffGrant scope brokerGeneration ->
    Either HandoffError ()
verifyRecoveryWithConfigGrant key binding wire configGrant =
    withVerifiedRecoveryWire key binding wire configGrant (const ())
