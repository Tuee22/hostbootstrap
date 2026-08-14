module RawFrameAuthorizeRootProject where

import HostBootstrap.Authority
    ( PreparePhase
    , ProjectVerb (ProjectUp)
    , RootInvocationAuthority
    , VerbUp
    )
import HostBootstrap.Authority.ProjectPlan (authorizeRootProject)
import HostBootstrap.Lifecycle.Mode
    ( AcquisitionJournal
    , BoundRunLease
    , LifecycleCursor
    , VerifiedPlanSnapshot
    )
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Frame (ProjectFrame, ValidatedContext)
import HostBootstrap.ProjectPlan.Snapshot (BoundPlanSnapshot, PlanDigestBinding)

data Configuration scope

rawFrameGate ::
    Root scope broker ->
    Verified scope spec digest ->
    Bound scope spec digest plan ->
    Binding scope spec digest plan ->
    Lease scope spec digest broker ->
    Plan scope spec plan config Configuration ->
    Journal scope plan broker ->
    Frame scope spec plan config frame ->
    Cursor scope plan frame broker ->
    Context scope plan frame ->
    ()
rawFrameGate root verified bound binding lease plan journal frame cursor validated =
    authorizeRootProject
        root
        ProjectUp
        verified
        bound
        binding
        lease
        plan
        journal
        frame
        cursor
        validated
        `seq` ()

type Root scope broker = RootInvocationAuthority scope broker VerbUp
type Verified scope spec digest = VerifiedPlanSnapshot scope spec digest
type Bound scope spec digest plan = BoundPlanSnapshot scope spec digest plan
type Binding scope spec digest plan = PlanDigestBinding scope spec digest plan
type Lease scope spec digest broker = BoundRunLease scope spec digest broker
type Plan scope spec plan config cfg = ProjectPlan scope spec plan config cfg
type Journal scope plan broker = AcquisitionJournal scope plan broker
type Frame scope spec plan config frame = ProjectFrame scope spec plan config frame
type Cursor scope plan frame broker = LifecycleCursor scope plan frame broker VerbUp PreparePhase
type Context scope plan frame = ValidatedContext scope plan frame
