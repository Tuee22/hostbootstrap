module ForgeRunId where

import HostBootstrap.Lifecycle.Mode (RunId)

data Run

-- A RunId is minted only inside the Harness acquisition's rank-2 continuation.
forgedRunId :: RunId Run
forgedRunId = RunId
