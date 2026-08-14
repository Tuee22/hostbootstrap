{-# LANGUAGE RankNTypes #-}

module EscapeAuthenticatedRootScopeRun where

import Data.ByteString (ByteString)
import HostBootstrap.Authority (InstalledProjectIdentity)
import HostBootstrap.Config.Vocab (Harness)
import HostBootstrap.Handoff

data Project
data CallerChosenRun

-- A verified Harness run is introduced only inside the rank-2 branch. It
-- cannot escape as evidence for a caller-selected run phantom.
escapeAuthenticatedRun ::
    InstalledProjectIdentity Project ->
    ProjectVerificationKey ->
    ByteString ->
    Either HandoffError (AuthenticatedRootScope (Harness Project CallerChosenRun))
escapeAuthenticatedRun project key raw =
    withAuthenticatedRootScopeFromWire
        project
        key
        raw
        (\_ _ -> error "Production is not a Harness result")
        (\authenticated _ -> authenticated)
