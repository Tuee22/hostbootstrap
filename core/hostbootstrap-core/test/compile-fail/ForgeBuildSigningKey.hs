module ForgeBuildSigningKey where

import HostBootstrap.Build

-- A caller cannot assert possession of the long-lived coordinator secret.
forgedSigningKey :: BuildSigningKey
forgedSigningKey = BuildSigningKey undefined
