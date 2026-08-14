module PassRawAdmissionToResumedReverseRoot where

-- The resume kernel is visible only as a package-internal wiring point. A
-- downstream caller cannot replace its hidden admission witness with a raw
-- token and thereby enter the private reverse-root protocol.
import HostBootstrap.Lifecycle.Mode (withResumedExistingBoundReverseRootKernel)

resumeWithRawToken = withResumedExistingBoundReverseRootKernel ()
