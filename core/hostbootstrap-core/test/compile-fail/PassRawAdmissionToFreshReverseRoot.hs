module PassRawAdmissionToFreshReverseRoot where

-- The fresh kernel is a package-internal wiring point. A downstream caller
-- cannot replace its hidden admission witness with a raw token and thereby
-- publish the private reverse-root Pending record.
import HostBootstrap.Lifecycle.Mode (withFreshExistingBoundReverseRootKernel)

freshWithRawToken = withFreshExistingBoundReverseRootKernel ()
