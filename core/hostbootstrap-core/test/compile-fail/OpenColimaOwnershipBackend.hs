{- | The OS-released lock/origin backend is entirely private. -}
module OpenColimaOwnershipBackend where

import HostBootstrap.Ensure.Colima (ColimaOwnershipBackend)

openBackend :: ColimaOwnershipBackend
openBackend = undefined
