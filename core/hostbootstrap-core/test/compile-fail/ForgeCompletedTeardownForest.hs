{-# LANGUAGE OverloadedStrings #-}

module ForgeCompletedTeardownForest where

import HostBootstrap.Authority (ProjectVerb (ProjectDestroy), VerbDestroy)
import HostBootstrap.Teardown

forged :: CompletedTeardownForest s p f VerbDestroy
forged = CompletedTeardownForest ProjectDestroy "plan-1" "frame" []
