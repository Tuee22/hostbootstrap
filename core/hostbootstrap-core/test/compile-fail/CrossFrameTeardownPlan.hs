module CrossFrameTeardownPlan where

import HostBootstrap.Teardown (DownVerb, TeardownPlan)

data Scope
data Plan
data FrameA
data FrameB

consumeFrameB :: TeardownPlan Scope Plan FrameB DownVerb -> ()
consumeFrameB _ = ()

-- The frame selected during projection remains part of the teardown-plan
-- identity even though the recursive-lifecycle-command forest deliberately
-- stays unframed at this boundary.
crossFrameTeardownPlan :: TeardownPlan Scope Plan FrameA DownVerb -> ()
crossFrameTeardownPlan projection = consumeFrameB projection
