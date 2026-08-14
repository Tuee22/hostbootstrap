module CallerFixedAuthenticatedRootScopeParser where

import Data.ByteString (ByteString)
import HostBootstrap.Authority (InstalledProjectIdentity)
import HostBootstrap.Config.Vocab (Harness)
import HostBootstrap.Handoff

data Project
data CallerChosenRun

-- Root-scope verification is a closed Production/Harness fold. There is no
-- parser whose caller gets to select a Harness run identity in its result.
decodeCallerChosenRun ::
    InstalledProjectIdentity Project ->
    ProjectVerificationKey ->
    ByteString ->
    Either HandoffError (AuthenticatedRootScope (Harness Project CallerChosenRun))
decodeCallerChosenRun = authenticatedRootScopeFromWire
