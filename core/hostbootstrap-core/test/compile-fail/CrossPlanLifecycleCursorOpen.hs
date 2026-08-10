module CrossPlanLifecycleCursorOpen where

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

data Scope
data SpecDigest
data PlanA
data PlanB
data ConfigId
data Frame
data BrokerGeneration

-- A frame admitted under another plan identity cannot open a cursor against
-- this acquisition journal.
openWrongPlan ::
    AcquisitionJournal Scope PlanA BrokerGeneration ->
    ProjectFrame Scope SpecDigest PlanB ConfigId Frame ->
    IO (Either LifecycleError ())
openWrongPlan journal frame =
    withLifecycleCursor journal frame ProjectUp Prepare (\_ -> pure ())
