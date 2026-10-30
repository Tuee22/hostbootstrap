module OpenRecoveryChildPackageDecoder where

-- A raw recovery package is decoded only at the package-owned recovery boundary.

import HostBootstrap.Handoff (
    recoveryChildPackageFromWireKernel,
 )
