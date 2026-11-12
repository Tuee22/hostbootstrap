{-# LANGUAGE RankNTypes #-}

module EscapeReenteredOwnershipEntry where

import HostBootstrap.Ownership.Clause (Bound)
import HostBootstrap.Ownership.Object (OwnershipFault)
import HostBootstrap.Ownership.Primitive (OwnershipRow, reenterStoredOwnedObject)
import HostBootstrap.Ownership.Tape (StoredOriginRecord)
import HostBootstrap.Protected (ProtectedSession)

-- Re-entering an object already owned is an entry, not a way around one: the
-- token it mints carries the protected session's own rank-2 index, so carrying
-- one out of the continuation has no type.
escapes ::
    OwnershipRow ->
    ProtectedSession session ->
    FilePath ->
    StoredOriginRecord session ->
    IO (Either OwnershipFault (Bound escaped object))
escapes row session target record =
    reenterStoredOwnedObject row session target record (\bound -> pure (Right bound))
