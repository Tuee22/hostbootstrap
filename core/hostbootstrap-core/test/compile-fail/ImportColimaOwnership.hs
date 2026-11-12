-- | Public callers cannot select the owning driver's interpreter or namespace.
module ImportColimaOwnership where

import HostBootstrap.Ensure.Colima.Ownership

badDocker = runManagedColimaDockerWith (\_ -> pure (Left "caller interpreter"))
badCleanup = cleanupManagedColimaProfileWith (\_ -> pure (Left "caller interpreter"))
