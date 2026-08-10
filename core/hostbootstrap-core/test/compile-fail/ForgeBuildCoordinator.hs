{-# LANGUAGE OverloadedStrings #-}

module ForgeBuildCoordinator where

import HostBootstrap.Build

data CoordinatorId

-- Only the active rank-2 bracket can join the provisioned key, coordinator
-- identity, and lifetime guard.
forgedCoordinator :: BuildCoordinator CoordinatorId
forgedCoordinator = BuildCoordinator undefined "coordinator" undefined
