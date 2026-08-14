module CoerceAcquisitionJournalAdmission where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (reopenAuthenticatedChildCursorKernel)

-- The hidden ordinary-data admission cannot be supplied by representational
-- coercion even when its type is inferred from the sealed public kernel.
openWithoutAdmission = reopenAuthenticatedChildCursorKernel (coerce ())
