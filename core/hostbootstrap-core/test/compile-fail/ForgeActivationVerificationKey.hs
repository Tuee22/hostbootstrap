module ForgeActivationVerificationKey where

import HostBootstrap.Activation

-- A caller cannot relabel arbitrary bytes as the installed verifier.
forgedVerificationKey :: ActivationVerificationKey
forgedVerificationKey = ActivationVerificationKey undefined
