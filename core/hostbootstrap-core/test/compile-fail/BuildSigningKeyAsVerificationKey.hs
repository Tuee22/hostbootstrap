module BuildSigningKeyAsVerificationKey where

import HostBootstrap.Build

-- The root-side secret and image-side installed public key are distinct types.
substituteSecret :: BuildSigningKey -> BuildVerificationKey
substituteSecret = id
