module ForgeGuestBootstrapStep where

import HostBootstrap.Ensure.GuestBootstrap (
    GuestBootstrapStep (InstallGuestProjectBinary),
    mkGuestBuiltBinary,
    mkGuestInstalledBinary,
    mkGuestPath,
 )

forged :: Either String GuestBootstrapStep
forged = do
    built <- mkGuestPath "/build/hostbootstrap-demo"
    installed <- mkGuestPath "/usr/local/bin/hostbootstrap-demo"
    pure (InstallGuestProjectBinary (mkGuestBuiltBinary built) (mkGuestInstalledBinary installed))
