{-# LANGUAGE DataKinds #-}

module ConstructRawLocalExposure where

import HostBootstrap.Network (loopbackExposure)

raw = loopbackExposure 30500
