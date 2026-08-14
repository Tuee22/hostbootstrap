module PassRawAdmissionToReverseRootTargetCursor where

-- The target cursor kernel is visible only as a package wiring point. A
-- downstream caller cannot replace its hidden acquisition admission witness
-- and independently supply a journal, frame, or reverse verb.
import HostBootstrap.Lifecycle.Session (withReverseRootTargetLifecycleCursorKernel)

targetCursorWithRawToken = withReverseRootTargetLifecycleCursorKernel ()
