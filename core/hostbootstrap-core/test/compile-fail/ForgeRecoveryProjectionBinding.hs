module ForgeRecoveryProjectionBinding where

import HostBootstrap.Handoff

forgedBinding ::
    RecoveryProjectionBinding
        scope brokerGeneration verb planDigest parentFrame childFrame wireDigest
forgedBinding = RecoveryProjectionBinding
