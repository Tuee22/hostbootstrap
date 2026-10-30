module PassFreshEvidenceToBoundSnapshot where

import HostBootstrap.Authority (InstalledProjectIdentity)
import HostBootstrap.Lifecycle.Mode (
    UnboundRunLease,
    VerifiedPlanSnapshot,
 )
import HostBootstrap.ProjectPlan.Snapshot (
    SnapshotError,
    withBoundPlanSnapshot,
 )
import HostBootstrap.ProjectScope (Production)
import HostBootstrap.Protected (ProtectedStore)

passUnboundLease ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    UnboundRunLease (Production projectId) brokerGeneration ->
    IO (Either SnapshotError ())
passUnboundLease store project unbound =
    withBoundPlanSnapshot
        store
        project
        (\_ -> pure ())
        (\_ _ _ _ _ _ _ -> pure ())
        unbound

passCallerSnapshot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
    IO (Either SnapshotError ())
passCallerSnapshot store project snapshot =
    withBoundPlanSnapshot
        store
        project
        (\_ -> pure ())
        (\_ _ _ _ _ _ _ -> pure ())
        snapshot
