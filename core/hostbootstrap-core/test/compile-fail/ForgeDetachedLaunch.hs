{- | The invocation *shape* of a child that outlives its launcher is a sealed
boundary (§ HH): the launch record, its running-child value, and the absolute
working directory and output sink have no public constructor, and the assembled
'System.Process.CreateProcess' is unreachable — so no call site can select the
stdio disposition that closed the host daemon's descriptors.
-}
module ForgeDetachedLaunch where

import HostBootstrap.Detached
import System.Process (CreateProcess)

-- The launch record is the whole boundary: if a caller could name it, the
-- stdio disposition would be a field it fills in rather than a fixed value.
forgedLaunch :: DetachedLaunch
forgedLaunch = DetachedLaunch

-- The running-child value is minted only by 'withDetachedChild', so it cannot
-- be conjured for a process the bracket never launched.
forgedChild :: DetachedChild child
forgedChild = DetachedChild

-- The working directory and output sink are absolute by construction; naming
-- their constructors would reintroduce a relative path.
forgedWorkingDirectory :: DetachedWorkingDirectory
forgedWorkingDirectory = DetachedWorkingDirectory "relative/dir"

forgedOutputSink :: DetachedOutputSink
forgedOutputSink = DetachedOutputSink "relative/sink"

-- The assembled process specification is private, so a caller cannot obtain
-- one and adjust it.
reachedProcessSpecification :: DetachedLaunch -> CreateProcess
reachedProcessSpecification = detachedProcess
