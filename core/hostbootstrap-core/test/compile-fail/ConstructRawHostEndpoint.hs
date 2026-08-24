{-# LANGUAGE DataKinds #-}

module ConstructRawHostEndpoint where

import HostBootstrap.Network (hostLocalEndpoint)

raw = hostLocalEndpoint "127.0.0.1:30500"
