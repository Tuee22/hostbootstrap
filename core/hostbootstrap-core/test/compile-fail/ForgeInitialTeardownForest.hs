module ForgeInitialTeardownForest where

import HostBootstrap.Teardown

data Scope
data Plan

-- openTeardownForest is the sole initial producer. A caller cannot choose an
-- arbitrary digest or initial node set by invoking the hidden constructor.
forgedForest :: TeardownForest Scope Plan DestroyVerb
forgedForest = TeardownForest destroyVerb "digest" []
