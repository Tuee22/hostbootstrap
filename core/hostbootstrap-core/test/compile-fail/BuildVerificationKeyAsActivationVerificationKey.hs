module BuildVerificationKeyAsActivationVerificationKey where

import HostBootstrap.Activation (ActivationVerificationKey)
import HostBootstrap.Build (BuildVerificationKey)

-- Build and Activation verification identities cannot cross protocol domains.
substituteBuildKey :: BuildVerificationKey -> ActivationVerificationKey
substituteBuildKey = id
