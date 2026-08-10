{-# LANGUAGE GADTs #-}

module EscapeBoundSnapshotPlanIdentity where

import HostBootstrap.Authority (InstalledProjectIdentity)
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , SnapshotError
    , withBoundPlanSnapshot
    )
import HostBootstrap.ProjectScope (Production)
import HostBootstrap.Protected (ProtectedStore)

data ChosenPlan

-- The Open continuation cannot package its fresh plan identity under a
-- caller-selected name.  The terminal continuation is deliberately bottom so
-- only the Open branch constrains the successful result.
data EscapedSnapshot projectId where
    EscapedSnapshot ::
        BoundPlanSnapshot
            (Production projectId)
            specDigest
            planDigest
            ChosenPlan ->
        EscapedSnapshot projectId

escapePlanIdentity ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    IO (Either SnapshotError (EscapedSnapshot projectId))
escapePlanIdentity store project =
    withBoundPlanSnapshot
        store
        project
        (\_closeKey -> undefined)
        (\_ _ _ _ snapshot _ _ -> pure (EscapedSnapshot snapshot))
