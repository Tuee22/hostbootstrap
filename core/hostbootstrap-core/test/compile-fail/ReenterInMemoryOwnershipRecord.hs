{-# LANGUAGE RankNTypes #-}

module ReenterInMemoryOwnershipRecord where

import HostBootstrap.Ownership.Object (ObjectIdentity, ObjectKind (OwnedDirectory), Origin (OriginAbsent), OwnershipFault, bindOriginRecord, originRecord)
import HostBootstrap.Ownership.Primitive (OwnershipRow, StoredOriginRecord, reenterStoredOwnedObject)
import HostBootstrap.Protected (ProtectedSession)

-- Shape-valid data was never returned by this protected entry's tape.
reenter :: OwnershipRow -> ProtectedSession session -> ObjectIdentity -> IO (Either OwnershipFault ())
reenter row session identity =
    case bindOriginRecord identity (originRecord OwnedDirectory OriginAbsent) of
        Left fault -> pure (Left fault)
        Right inMemory -> reenterStoredOwnedObject row session "/in-memory" inMemory (\_ -> pure (Right ()))
