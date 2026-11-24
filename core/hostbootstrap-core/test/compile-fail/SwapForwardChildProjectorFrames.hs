module SwapForwardChildProjectorFrames where

import HostBootstrap.CLI (ChildFrameId, ParentFrameId, ProjectSpecBuilder, addForwardChildPlan)
import HostBootstrap.Step (StepPlan)

-- A projector cannot use the child coordinate where a parent is required.
needsParent :: ParentFrameId -> Either String (FilePath, cfg scope, StepPlan)
needsParent _ = undefined

childIdentity :: ChildFrameId -> ChildFrameId
childIdentity = id

installSwapped :: ProjectSpecBuilder cfg tcfg -> ProjectSpecBuilder cfg tcfg
installSwapped = addForwardChildPlan (\_ _ child _ -> needsParent (childIdentity child))
