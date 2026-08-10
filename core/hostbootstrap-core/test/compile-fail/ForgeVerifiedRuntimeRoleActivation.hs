module ForgeVerifiedRuntimeRoleActivation where

import HostBootstrap.Activation

-- Startup verification is the only producer of the inseparable package.
forgedActivation ::
    VerifiedRuntimeRoleActivation scope plan spec binary frame revision instanceId
forgedActivation = VerifiedRuntimeRoleActivation undefined undefined undefined
