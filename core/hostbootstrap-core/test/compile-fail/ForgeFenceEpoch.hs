module ForgeFenceEpoch where

import Data.Word (Word64)
import HostBootstrap.Lifecycle.Session (FenceEpoch)

forgedFence :: Word64 -> FenceEpoch scope planId
forgedFence generation = FenceEpoch generation
