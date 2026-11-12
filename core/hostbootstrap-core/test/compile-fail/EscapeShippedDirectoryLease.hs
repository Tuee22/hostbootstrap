{-# LANGUAGE RankNTypes #-}

module EscapeShippedDirectoryLease where

import HostBootstrap.Ownership.Object (OwnershipFault)
import HostBootstrap.Ownership.Primitive (OwnershipRow)
import HostBootstrap.Ownership.Shipped (ShippedDirectoryLease, ShippedOwnership, withShippedDirectoryLease)

escape ::
    OwnershipRow ->
    ShippedOwnership ->
    IO (Either OwnershipFault (ShippedDirectoryLease escaped))
escape row transaction = withShippedDirectoryLease row transaction pure
