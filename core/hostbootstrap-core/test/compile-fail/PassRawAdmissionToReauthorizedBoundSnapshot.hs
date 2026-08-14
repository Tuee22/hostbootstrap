module PassRawAdmissionToReauthorizedBoundSnapshot where

-- The reverse-root Snapshot facade is visible only as a package wiring point.
-- A downstream caller cannot replace its hidden admission witness with a raw
-- token and thereby enter either fresh admission or recorded-intent recovery.
import HostBootstrap.ProjectPlan.Snapshot (withReauthorizedBoundPlanSnapshotKernel)

reauthorizeWithRawToken = withReauthorizedBoundPlanSnapshotKernel ()
