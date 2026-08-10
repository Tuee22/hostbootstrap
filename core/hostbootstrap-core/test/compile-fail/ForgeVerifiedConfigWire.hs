{-# LANGUAGE OverloadedStrings #-}

module ForgeVerifiedConfigWire where

import HostBootstrap.Config.Schema

data Scope
data Digest
data ConfigIdentity

forgedWire :: VerifiedConfigWire Scope Digest ConfigIdentity
forgedWire = VerifiedConfigWire "digest"
