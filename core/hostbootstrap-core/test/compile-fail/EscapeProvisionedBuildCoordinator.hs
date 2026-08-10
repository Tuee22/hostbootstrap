{-# LANGUAGE OverloadedStrings #-}

module EscapeProvisionedBuildCoordinator where

import HostBootstrap.Build

data ChosenCoordinator

-- The provisioned signing key is long-lived; each active use still receives a
-- fresh coordinator identity that a caller cannot choose in the result.
escapeCoordinator :: BuildSigningKey -> IO (BuildCoordinator ChosenCoordinator)
escapeCoordinator signingKey =
    withBuildCoordinator signingKey "coordinator-digest" pure
