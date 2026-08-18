module MutateBeforeOwnershipRecord where

import HostBootstrap.Ownership.Clause (Entered)
import HostBootstrap.Ownership.Object (ObjectIdentity, OwnershipFault)
import HostBootstrap.Ownership.Primitive (OwnershipRow, createOwnedDirectory)

-- Clause 2 comes before the mutation: a directory is created from the record
-- that was published, never from the entry alone.
mutates ::
    OwnershipRow ->
    Entered session object ->
    IO (Either OwnershipFault ObjectIdentity)
mutates row entered = createOwnedDirectory row entered
