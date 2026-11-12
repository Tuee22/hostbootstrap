module UpdateStoredOwnershipVersion where

import HostBootstrap.Ownership.Tape (StoredOriginRecord, storedRecordVersion)
import HostBootstrap.Protected (RecordVersion)

-- A caller cannot rewrite the exact version returned by the protected store.
replaceVersion :: StoredOriginRecord session -> RecordVersion -> StoredOriginRecord session
replaceVersion stored version = stored { storedRecordVersion = version }
