{-# LANGUAGE OverloadedStrings #-}

module ForgeProtectedStoreIdentity where

import HostBootstrap.Protected (ProtectedStoreIdentity)

forged :: ProtectedStoreIdentity
forged = ProtectedStoreIdentity "forged-store"
