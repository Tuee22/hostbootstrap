{-# LANGUAGE ScopedTypeVariables #-}

module TerminalReceivesBoundPlanSnapshot where

import HostBootstrap.Authority (InstalledProjectIdentity)
import HostBootstrap.Lifecycle.Mode (InvocationCloseKey)
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , SnapshotError
    , withBoundPlanSnapshot
    )
import HostBootstrap.ProjectScope (Production)
import HostBootstrap.Protected (ProtectedStore)

data SpecDigest
data PlanDigest
data PlanId

terminalWithPlan ::
    forall projectId.
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    IO (Either SnapshotError ())
terminalWithPlan store project =
    withBoundPlanSnapshot
        store
        project
        ( \_closeKey
            (_ :: BoundPlanSnapshot (Production projectId) SpecDigest PlanDigest PlanId) ->
                pure ()
        )
        (\_ _ _ _ _ _ _ -> pure ())
