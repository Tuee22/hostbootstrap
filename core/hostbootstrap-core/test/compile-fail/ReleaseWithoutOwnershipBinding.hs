module ReleaseWithoutOwnershipBinding where

import HostBootstrap.Ownership.Clause (Bound)
import HostBootstrap.Ownership.Object (OriginRecord, OwnershipFault)
import HostBootstrap.Ownership.Primitive (OwnershipRow, releaseOwnedObject)

-- Clause 4 consumes the re-observation, never the binding: a release that has
-- not just compared the identity has no term.
releases ::
    OwnershipRow ->
    Bound session object ->
    (OriginRecord -> IO (Either OwnershipFault ())) ->
    IO (Either OwnershipFault ())
releases row bound forget = releaseOwnedObject row bound forget
