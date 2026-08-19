{-# LANGUAGE RankNTypes #-}

module EscapeReenteredOwnershipEntry where

import HostBootstrap.Ownership.Clause (Bound)
import HostBootstrap.Ownership.Object (OriginRecord, OwnershipFault)
import HostBootstrap.Ownership.Primitive (OwnershipRow, reenterOwnedObject)
import HostBootstrap.Protected (ProtectedSession)

-- Re-entering an object already owned is an entry, not a way around one: the
-- token it mints carries the protected session's own rank-2 index, so carrying
-- one out of the continuation has no type.
escapes ::
    OwnershipRow ->
    ProtectedSession session ->
    FilePath ->
    OriginRecord ->
    IO (Either OwnershipFault (Bound escaped object))
escapes row session target record =
    reenterOwnedObject row session target record (\bound -> pure (Right bound))
