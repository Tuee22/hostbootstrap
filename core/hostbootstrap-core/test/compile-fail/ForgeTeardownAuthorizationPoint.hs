{-# LANGUAGE OverloadedStrings #-}

module ForgeTeardownAuthorizationPoint where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

forged :: TeardownAuthorizationPoint s p f VerbDestroy
forged = TeardownAuthorizationPoint
