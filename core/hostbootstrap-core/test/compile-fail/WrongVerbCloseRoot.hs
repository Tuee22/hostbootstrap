module WrongVerbCloseRoot where

import HostBootstrap.Authority
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Lifecycle.Mode
import HostBootstrap.Lifecycle.Session (VerifiedAllSessionsClosed)
import HostBootstrap.Teardown (DestroySettled)

-- The complete settled-closure boundary still requires a Destroy root.
settledFromUp ::
    RootInvocationAuthority (Production project) generation VerbUp ->
    BoundRunLease (Production project) spec plan generation ->
    VerifiedAllSessionsClosed (Production project) planId ->
    DestroySettled (Production project) planId ->
    Either ModeError (ProductionClosureAuthorization project generation)
settledFromUp = authorizeProductionDestroy
