{-# LANGUAGE RankNTypes #-}

module EscapeOwnershipClauseEntry where

import HostBootstrap.Ownership.Clause (Entered)
import HostBootstrap.Protected (ProtectedError, ProtectedSession, ProtectedStore, withProtectedEntry)

data Obj

-- A clause token may not outlive the entry that authorized it: the session index
-- is the protected entry's own rank-2 variable, so carrying one out of the
-- continuation has no type.
escapes ::
    ProtectedStore ->
    (forall session. ProtectedSession session -> IO (Either ProtectedError (Entered session Obj))) ->
    IO (Either ProtectedError (Entered escaped Obj))
escapes store produce = withProtectedEntry store produce
