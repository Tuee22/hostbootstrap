{-# LANGUAGE RankNTypes #-}

module EscapeStoredOwnershipRecord where

import HostBootstrap.Ownership.Object (OwnershipFault)
import HostBootstrap.Ownership.Primitive (OwnershipRow, StoredOriginRecord, reenterStoredOwnedObject)
import HostBootstrap.Protected (ProtectedSession)

-- A value minted under the first entry cannot be consumed under the second.
crosses ::
    OwnershipRow ->
    ProtectedSession session ->
    ProtectedSession other ->
    StoredOriginRecord session ->
    IO (Either OwnershipFault ())
crosses row _first second stored =
    reenterStoredOwnedObject row second "/another-entry" stored (\_ -> pure (Right ()))
