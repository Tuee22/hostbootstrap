{-# LANGUAGE RankNTypes #-}

module CrossVerifiedConfigHandoffPair (retained) where

import HostBootstrap.Authority (ProjectVerb)
import HostBootstrap.Config.Schema (
    ValidatedConfig,
    VerifiedConfigWire,
    withVerifiedConfigHandoff,
 )
import HostBootstrap.Handoff (HandoffError, VerifiedHandoff)

retained ::
    ProjectVerb verb ->
    VerifiedHandoff scope generation ->
    VerifiedConfigWire scope digest configIdA ->
    ValidatedConfig scope specDigest configIdB config ->
    Either HandoffError ()
retained verb handoff wire config =
    withVerifiedConfigHandoff verb handoff wire config (\_ -> ())
