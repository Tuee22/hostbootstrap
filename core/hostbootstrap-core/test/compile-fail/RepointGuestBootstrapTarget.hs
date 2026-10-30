module RepointGuestBootstrapTarget where

import HostBootstrap.Ensure.GuestBootstrap (
    GuestBootstrapTarget,
    guestSourceRoot,
    mkGuestPath,
    mkGuestSourceRoot,
 )

repoint :: GuestBootstrapTarget -> Either String GuestBootstrapTarget
repoint target = do
    source <- mkGuestPath "/other/source"
    pure target{guestSourceRoot = mkGuestSourceRoot source}
