module ForgeOwnershipOriginRecord where

import HostBootstrap.Ownership.Object (ObjectIdentity, ObjectKind, Origin, OriginRecord)

-- A record's binding is attached by its own producer, so no caller may assemble
-- a record that already claims one.
forged :: ObjectKind -> Origin -> ObjectIdentity -> OriginRecord
forged kind origin identity = OriginRecord kind origin (Just identity)
