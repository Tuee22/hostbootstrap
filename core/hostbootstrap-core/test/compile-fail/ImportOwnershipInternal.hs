module ImportOwnershipInternal where

import HostBootstrap.Ownership.Internal (Entered (Entered))

hidden :: Entered session object -> ()
hidden _ = ()
