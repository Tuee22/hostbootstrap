module ForgeVerifiedRecoveryHandoff where

import HostBootstrap.Handoff

forgedHandoff ::
    VerifiedRecoveryHandoff
        scope brokerGeneration planDigest parentFrame childFrame wireDigest wireId verb
forgedHandoff = VerifiedRecoveryHandoff undefined undefined
