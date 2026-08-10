module ActivationSigningKeyAsVerificationKey where

import HostBootstrap.Activation

-- The root-side Activation secret and runtime-side installed public key are
-- distinct authority families even though both use Ed25519 internally.
substituteSecret :: ActivationSigningKey -> ActivationVerificationKey
substituteSecret = id
