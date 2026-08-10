module BuildCoordinatorCannotExportVerificationKey where

import Data.ByteString (ByteString)
import HostBootstrap.Build

-- The public verifier is derived from the provisioned signing key before the
-- coordinator bracket. No live-broker accessor can self-certify a grant.
exportFromCoordinator :: BuildCoordinator coordinatorId -> ByteString
exportFromCoordinator = buildCoordinatorKey
