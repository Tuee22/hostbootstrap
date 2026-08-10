module ForgeTeardownPlan where

import HostBootstrap.Teardown

data Scope
data Plan
data Frame

-- Only the exact plan/current-frame projection and the tracked live
-- compatibility bridge can produce a teardown plan; its constructor is hidden.
forgedProjection :: TeardownPlan Scope Plan Frame DestroyVerb
forgedProjection = TeardownPlan destroyVerb "digest" "frame" []
