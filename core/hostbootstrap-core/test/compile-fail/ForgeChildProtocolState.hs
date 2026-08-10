module ForgeChildProtocolState where

import HostBootstrap.Handoff

-- A caller cannot jump directly to the post-admission protocol state.
forgedRunning :: ChildProtocolState
forgedRunning = ChildRunning 1
