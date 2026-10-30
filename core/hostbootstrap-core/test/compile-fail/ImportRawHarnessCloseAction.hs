module ImportRawHarnessCloseAction where

-- The indexed close control and its consumer remain behind protected Harness admission.

import HostBootstrap.Harness.Ownership (
    newOwnedHarnessCloseControl,
    consumeOwnedHarnessClose,
 )
