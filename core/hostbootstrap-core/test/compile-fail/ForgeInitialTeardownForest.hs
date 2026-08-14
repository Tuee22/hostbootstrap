module ForgeInitialTeardownForest where

import HostBootstrap.Authority (ProjectVerb (ProjectDestroy), VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan
data Frame

-- openTeardownForest is the sole initial producer. A caller cannot choose an
-- arbitrary digest or initial node set by invoking the hidden constructor.
forgedForest :: TeardownForest Scope Plan Frame VerbDestroy
forgedForest = TeardownForest undefined []
