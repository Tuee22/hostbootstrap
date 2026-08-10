module ForgeHarnessMode where

import HostBootstrap.Lifecycle.Mode (HarnessMode)

data Run

-- The public Harness tag is opaque; a caller cannot attach an invented run
-- index to a term-level mode witness.
forgedHarnessMode :: HarnessMode Run
forgedHarnessMode = HarnessMode
