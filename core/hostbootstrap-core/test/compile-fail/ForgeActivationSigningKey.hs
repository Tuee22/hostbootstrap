module ForgeActivationSigningKey where

import HostBootstrap.Activation

-- A caller cannot assert possession of the long-lived activation secret.
forgedSigningKey :: ActivationSigningKey
forgedSigningKey = ActivationSigningKey undefined
