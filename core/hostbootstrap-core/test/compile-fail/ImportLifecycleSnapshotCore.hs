module ImportLifecycleSnapshotCore where

import HostBootstrap.Lifecycle.Snapshot.Core (StablePlanSnapshot)

retained :: StablePlanSnapshot -> StablePlanSnapshot
retained = id
