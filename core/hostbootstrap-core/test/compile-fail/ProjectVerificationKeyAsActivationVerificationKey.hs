module ProjectVerificationKeyAsActivationVerificationKey where

import HostBootstrap.Activation (ActivationVerificationKey)
import HostBootstrap.Handoff (ProjectVerificationKey)

-- Handoff and Activation verification identities are provisioned separately.
substituteHandoffKey :: ProjectVerificationKey -> ActivationVerificationKey
substituteHandoffKey = id
