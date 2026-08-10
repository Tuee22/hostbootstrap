module RecoveryWireGrantAsActivationGrant where

import HostBootstrap.Activation (ActivationGrant)
import HostBootstrap.Handoff (RecoveryWireGrant)

substituteRecoveryGrant ::
    RecoveryWireGrant scope broker verb plan parent child digest ->
    ActivationGrant
substituteRecoveryGrant = id
