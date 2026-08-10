{-# LANGUAGE OverloadedStrings #-}

module ForgeBuildCommandAuthority where

import HostBootstrap.Build

data Project
data Spec
data Config

-- Narrow command authority is derived from an exact verified frame/invocation
-- pair and cannot be asserted directly.
forgedCommand :: BuildCommandAuthority Project Spec Config
forgedCommand = BuildCommandAuthority CheckCodePhase "image-build-container-0"
