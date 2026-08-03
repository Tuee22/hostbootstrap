module OpenHarnessAuthorityFromText where

import HostBootstrap.Config.Vocab (withHarnessAuthority)

-- Arbitrary text cannot open a generative Harness authority. The only producer
-- is the protected typed lifecycle root.
opened :: ()
opened = withHarnessAuthority "forged-run" (const ())
