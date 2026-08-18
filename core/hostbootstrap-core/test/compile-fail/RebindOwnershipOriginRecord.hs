module RebindOwnershipOriginRecord where

import HostBootstrap.Ownership.Object (ObjectIdentity, OriginRecord, originRecordBinding)

-- The record carries no updatable field, so a binding cannot be replaced by a
-- record update.
rebound :: OriginRecord -> ObjectIdentity -> OriginRecord
rebound record identity = record{originRecordBinding = Just identity}
