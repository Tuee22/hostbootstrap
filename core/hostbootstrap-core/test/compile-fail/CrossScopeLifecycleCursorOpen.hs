module CrossScopeLifecycleCursorOpen where

import HostBootstrap.Authority
    ( LifecyclePhase (Prepare)
    , ProjectVerb (ProjectUp)
    )
import HostBootstrap.Lifecycle.Session
    ( AcquisitionJournal
    , LifecycleError
    , withLifecycleCursor
    )
import HostBootstrap.ProjectPlan.Frame (ProjectFrame)

data ScopeA
data ScopeB
data SpecDigest
data PlanId
data ConfigId
data Frame
data BrokerGeneration

-- A plan-local frame from another project scope cannot open a cursor against
-- this acquisition journal.
openWrongScope ::
    AcquisitionJournal ScopeA PlanId BrokerGeneration ->
    ProjectFrame ScopeB SpecDigest PlanId ConfigId Frame ->
    IO (Either LifecycleError ())
openWrongScope journal frame =
    withLifecycleCursor journal frame ProjectUp Prepare (\_ -> pure ())
