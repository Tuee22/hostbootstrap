module UpdateStoredOwnershipRecord where

import HostBootstrap.Ownership.Object (OriginRecord)
import HostBootstrap.Ownership.Tape (StoredOriginRecord, storedOriginRecord)

-- A store read cannot be changed into caller-supplied authority after reading.
replaceBody :: StoredOriginRecord session -> OriginRecord -> StoredOriginRecord session
replaceBody stored inMemory = stored { storedOriginRecord = inMemory }
