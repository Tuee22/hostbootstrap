module ForgeHarnessLifecycle where

import HostBootstrap.Harness (HarnessLifecycle (HarnessLifecycle))

-- The public Harness facade exposes only the lifecycle package and its
-- eliminators; its data constructor cannot be imported from that facade.
forged :: HarnessLifecycle
forged = HarnessLifecycle (pure ()) (pure ())
