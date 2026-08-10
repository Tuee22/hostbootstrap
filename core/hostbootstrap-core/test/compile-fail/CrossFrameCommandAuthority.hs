module CrossFrameCommandAuthority where

import Data.Coerce (coerce)
import HostBootstrap.Authority

data Scope
data Plan
data FrameA
data FrameB
data Epoch

wrongFrame ::
    CommandAuthority Scope Plan FrameA Epoch VerbUp ExecutePhase ->
    CommandAuthority Scope Plan FrameB Epoch VerbUp ExecutePhase
wrongFrame = coerce
