module ForgeBuildVerificationKey where

import HostBootstrap.Build

-- A caller cannot relabel arbitrary bytes as the independently installed key.
forgedVerificationKey :: BuildVerificationKey
forgedVerificationKey = BuildVerificationKey undefined
