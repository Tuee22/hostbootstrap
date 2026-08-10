module ForgeActivationSigningPolicy where

import HostBootstrap.Activation

-- A caller cannot bypass manifest validation and the non-empty exact allowlist.
forgedPolicy :: ActivationSigningPolicy
forgedPolicy = ActivationSigningPolicy []
