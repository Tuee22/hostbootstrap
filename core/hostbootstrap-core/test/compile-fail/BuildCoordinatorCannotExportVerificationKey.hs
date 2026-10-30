module BuildCoordinatorCannotExportVerificationKey where

-- Provisioned signing state cannot be recovered from a live opaque coordinator.

import HostBootstrap.Build (
    coordinatorSigningKey,
 )
