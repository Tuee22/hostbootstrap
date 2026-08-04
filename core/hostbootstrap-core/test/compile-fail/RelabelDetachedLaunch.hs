{- | A hidden constructor alone does not seal a record: an exported field
accessor still admits record update, which would let a caller re-point a launch
it was handed. 'DetachedLaunch' therefore exports no field accessor at all, so
there is no field name to update through.

This is a separate fixture because a not-in-scope record field aborts GHC's
renamer, which would suppress every other diagnostic in
'ForgeDetachedLaunch.hs'.
-}
module RelabelDetachedLaunch where

import HostBootstrap.Detached

relabelledLaunch :: DetachedLaunch -> DetachedLaunch
relabelledLaunch launch = launch{dlArguments = ["service", "run"]}
