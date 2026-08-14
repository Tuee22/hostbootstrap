module CrossFrameLocalWork where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan
data FrameA
data FrameB

consumeFrameB :: LocalWork Scope Plan FrameB VerbDestroy -> ()
consumeFrameB _ = ()

crossFrameLocal :: LocalWork Scope Plan FrameA VerbDestroy -> ()
crossFrameLocal = consumeFrameB
