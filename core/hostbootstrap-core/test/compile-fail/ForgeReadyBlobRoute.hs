{-# LANGUAGE DataKinds #-}

-- | A blob-route witness must be settled from an observation, never built.
module ForgeReadyBlobRoute where

import HostBootstrap.RegistryPlan

forged :: ReadyBlobRoute client store
forged = ReadyBlobRoute 1
