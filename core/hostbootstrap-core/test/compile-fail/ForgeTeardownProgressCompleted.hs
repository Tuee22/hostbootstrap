{-# LANGUAGE OverloadedStrings #-}

module ForgeTeardownProgressCompleted where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

forged :: CompletedTeardownForest s p f VerbDestroy -> TeardownProgress s p f VerbDestroy
forged completed = ProgressCompleted completed
