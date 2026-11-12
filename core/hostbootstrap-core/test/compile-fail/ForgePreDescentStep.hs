{-# LANGUAGE OverloadedStrings #-}

module ForgePreDescentStep where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

forged :: PreDescentStep s p f VerbDestroy
forged = PreDescentStep
