module EscapeLifecycleCursorFrame where

import HostBootstrap.Authority
    ( LifecyclePhase (Prepare)
    , PreparePhase
    , ProjectVerb (ProjectUp)
    , VerbUp
    )
import HostBootstrap.Config.Class (ProjectCfg)
import HostBootstrap.Context (BinaryContext)
import HostBootstrap.Lifecycle.Session
    ( AcquisitionJournal
    , LifecycleCursor
    , LifecycleError
    , withLifecycleCursor
    )
import HostBootstrap.ProjectPlan (ProjectPlan)
import HostBootstrap.ProjectPlan.Frame (FrameError, withCurrentFrame)

data ChosenFrame

-- The rank-2 frame identity introduced by withCurrentFrame cannot escape in a
-- lifecycle cursor chosen by the caller.
escapeFrame ::
    ProjectCfg cfg =>
    ProjectPlan scope specDigest planId configId cfg ->
    AcquisitionJournal scope planId brokerGeneration ->
    BinaryContext ->
    Either
        FrameError
        ( IO
            ( Either
                LifecycleError
                ( LifecycleCursor
                    scope
                    planId
                    ChosenFrame
                    brokerGeneration
                    VerbUp
                    PreparePhase
                )
            )
        )
escapeFrame plan journal context =
    withCurrentFrame plan context $ \_current projectFrame _validated ->
        withLifecycleCursor journal projectFrame ProjectUp Prepare pure
