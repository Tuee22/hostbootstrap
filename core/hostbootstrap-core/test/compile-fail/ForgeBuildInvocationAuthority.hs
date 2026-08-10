{-# LANGUAGE OverloadedStrings #-}

module ForgeBuildInvocationAuthority where

import HostBootstrap.Build

data Project
data Spec
data Config
data Build
data Source
data Builder

-- Only independent-key verification and local measurement mint invocation
-- authority and its one-use phase state.
forgedInvocation :: BuildInvocationAuthority Project Spec Config Build Source Builder
forgedInvocation = BuildInvocationAuthority "build-7" "source-digest" undefined
