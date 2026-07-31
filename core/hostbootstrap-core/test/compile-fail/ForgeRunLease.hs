module ForgeRunLease where

import HostBootstrap.Lifecycle.Mode

-- Leases exist only where the protected compare-and-swap that recorded them
-- succeeded; neither constructor is public.
forgedUnbound :: UnboundRunLease scope brokerGeneration
forgedUnbound = UnboundRunLease (RunId "forged") undefined

forgedBound :: BoundRunLease scope specDigest planDigest brokerGeneration
forgedBound = BoundRunLease (RunId "forged") "spec" "plan" undefined
