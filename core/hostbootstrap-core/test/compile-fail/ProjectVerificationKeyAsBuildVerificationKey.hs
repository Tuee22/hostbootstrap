module ProjectVerificationKeyAsBuildVerificationKey where

import HostBootstrap.Build (BuildVerificationKey)
import HostBootstrap.Handoff (ProjectVerificationKey)

-- Handoff and build verification identities are separately provisioned and
-- cannot be substituted merely because both use Ed25519 internally.
substituteProjectKey :: ProjectVerificationKey -> BuildVerificationKey
substituteProjectKey = id
