module OpenTeardownForestWithCurrentFrame where

import HostBootstrap.Authority (VerbDown)
import HostBootstrap.ProjectPlan.Frame (CurrentFrame)
import HostBootstrap.Teardown

data Scope
data Plan
data Frame

-- The opener consumes the already frame-indexed projection. It cannot accept a
-- second frame witness that might disagree with the projection.
openWithSecondFrame ::
    CurrentFrame Scope Plan Frame ->
    TeardownPlan Scope Plan Frame VerbDown ->
    Either TeardownError (TeardownForest Scope Plan Frame VerbDown)
openWithSecondFrame = openTeardownForest
