module ForgeCurrentFrame where

import HostBootstrap.ProjectPlan.Frame (CurrentFrame)

data Scope
data PlanId
data Frame

-- Frame evidence is minted only by withCurrentFrame's rank-2 continuation.
forgedCurrentFrame :: CurrentFrame Scope PlanId Frame
forgedCurrentFrame = CurrentFrame
