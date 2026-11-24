{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module FinalizeProjectSpecWithScopeKind where

import HostBootstrap.CLI (ChildFrameId, ParentFrameId)
import HostBootstrap.Config.Class (ProjectCodec)
import HostBootstrap.Config.Fields (ScopeKind (HarnessScope))
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Lift.Context (LiftContext)
import HostBootstrap.ProjectPlan.Construct (withFinalizedProjectSpec)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.Service (ServiceRegistry)
import HostBootstrap.Step (StepPlan, StepPlanError)

-- A caller cannot select a Harness tag for a Production codec.
wrongScope ::
    forall projectId specDigest cfg.
    ProjectCodec (Production projectId) specDigest cfg ->
    ServiceRegistry cfg ->
    (forall scope rootId. CanonicalProjectRoot scope rootId -> cfg scope -> Either StepPlanError StepPlan) ->
    (forall scope. cfg scope -> ParentFrameId -> ChildFrameId -> LiftContext -> Either String (FilePath, cfg scope, StepPlan)) ->
    ()
wrongScope codec services builder projector =
    withFinalizedProjectSpec @(Production projectId) @specDigest @cfg @()
        HarnessScope codec services builder projector (const ())
