module OpenRunIdFromText where

-- Only the private lifecycle owner may reify a run key as generative run evidence.

import HostBootstrap.Lifecycle.Mode (
    withReifiedRunId,
 )
