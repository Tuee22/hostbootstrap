module OpenFrameExecutorGate where

-- The public prepared facade exposes no gate minting and no gate-package
-- codec, so a consumer cannot mint the local gate a storeless frame runs
-- behind, read the root's durable attempt and journal version out of a
-- package, or render the ordered key list a signed grant is compared against.
import HostBootstrap.Lifecycle.Prepared
    ( mintPreparedGate
    , readPreparedGatePackageKernel
    , readPreparedGatePackagesKernel
    , renderPreparedNodeKeysKernel
    )
