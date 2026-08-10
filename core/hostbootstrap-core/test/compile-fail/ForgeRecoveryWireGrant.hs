module ForgeRecoveryWireGrant where

import HostBootstrap.Handoff

forgedGrant ::
    RecoveryWireGrant
        scope brokerGeneration verb planDigest parentFrame childFrame wireDigest
forgedGrant = RecoveryWireGrant undefined
