module CrossSnapshotResourceRecordSet where

import HostBootstrap.Lifecycle.Mode
    ( ModeError
    , VerifiedPlanSnapshot
    , withVerifiedResourceRecordSet
    )
import HostBootstrap.ProjectPlan.Snapshot (BoundPlanSnapshot)
import HostBootstrap.Protected (ProtectedSession)

crossSnapshot ::
    ProtectedSession session ->
    VerifiedPlanSnapshot scope specDigest firstPlanDigest ->
    BoundPlanSnapshot scope specDigest secondPlanDigest planId ->
    IO (Either ModeError ())
crossSnapshot session verified bound =
    withVerifiedResourceRecordSet session verified bound (const ())
