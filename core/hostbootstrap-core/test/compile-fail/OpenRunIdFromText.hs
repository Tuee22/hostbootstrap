module OpenRunIdFromText where

-- Text is only a diagnostic/key projection. There is intentionally no public
-- inverse that lets a caller select a run identity.
import HostBootstrap.Lifecycle.Mode (RunId, mkRunId)
