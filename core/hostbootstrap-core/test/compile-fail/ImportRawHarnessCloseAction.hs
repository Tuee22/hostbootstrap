module ImportRawHarnessCloseAction where

import HostBootstrap.Harness.Ownership (stageOwnedHarnessClose)

-- Terminal Harness close is owned by the package-private indexed control. A
-- public caller cannot install an arbitrary IO action that merely reports
-- success while leaving the exact lease and mode open.
rawCloseActionCannotEscape :: ()
rawCloseActionCannotEscape = stageOwnedHarnessClose `seq` ()
