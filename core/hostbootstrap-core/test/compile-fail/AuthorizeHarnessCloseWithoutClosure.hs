module AuthorizeHarnessCloseWithoutClosure where

import Data.Word (Word64)
import HostBootstrap.Authority (InstalledProjectIdentity)
import HostBootstrap.Lifecycle.Mode (
    BoundRunLease,
    HarnessCloseAuthorization,
    HarnessCloseRoot,
    HarnessMode,
    ModeError,
    ProjectModeLease,
    authorizeHarnessClose,
 )
import HostBootstrap.Lifecycle.Session (VerifiedAllSessionsClosed)
import HostBootstrap.ProjectScope (Harness)
import HostBootstrap.Protected (ProtectedSession)

data Project
data Run
data Specification
data PlanDigest
data Plan
data Broker

-- The old call shape put the closing epoch immediately after the closed-session
-- proof. It cannot authorize a Harness close now: exact settled-destroy closure
-- evidence is a mandatory argument before any Closing epoch may be persisted.
missingSettledDestroy ::
    ProtectedSession session ->
    InstalledProjectIdentity Project ->
    HarnessCloseRoot Project Run Broker ->
    ProjectModeLease Project (HarnessMode Run) Broker ->
    BoundRunLease (Harness Project Run) Specification PlanDigest Broker ->
    VerifiedAllSessionsClosed (Harness Project Run) Plan ->
    Word64 ->
    IO (Either ModeError (HarnessCloseAuthorization Project Run))
missingSettledDestroy session project closeRoot modeLease bound closed epoch =
    authorizeHarnessClose
        session
        project
        closeRoot
        modeLease
        bound
        closed
        epoch
        1
