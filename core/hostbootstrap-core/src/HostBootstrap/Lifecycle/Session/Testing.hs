{- | The durable state a lifecycle transaction leaves when it is interrupted.

A crash between the redo coordinator's three steps is not an event a fixture
has to reproduce; it is a /value/ the store is left holding — an @Applying@
coordinator record naming a descriptor, plus however many of that descriptor's
targets were already stamped with its sequence. This module exposes exactly the
vocabulary needed to write that value and nothing else, so a fixture builds the
state and then re-enters the ordinary entry point, and the recovery driver
under test needs no cooperation from the code under test.

That is deliberately the opposite of a crash point. A branch in the coordinator
that exists for a fixture is a path production never takes, so a gate that
drives it agrees with a shape nothing else produces — and it ships to operators.
Here the coordinator is untouched, the encoding is the one it writes, and the
only thing the fixture supplies is a record.

It mints no authority. There is no 'HostBootstrap.Lifecycle.Transaction.TransactionPermit'
constructor, no record-key minter beyond the coordinator's own, and no
transaction runner; a caller holding a descriptor holds a description of work,
never permission to perform it.
-}
module HostBootstrap.Lifecycle.Session.Testing (
    -- * The interrupted coordinator record
    CoordinatorState (..),
    TransactionDescriptor (..),
    TxnKind (..),
    coordinatorKey,
    encodeCoordinator,

    -- * The targets it names
    TransactionTarget,
    projectTransactionTarget,
    sessionTransactionTarget,
    operationTransactionTarget,
    stampTarget,

    -- * Reading a materialized target back
    TransactionRecord (..),
    readTransactionRecord,
    TransactionError,
    transactionErrorMessage,
) where

import HostBootstrap.Lifecycle.Transaction (
    CoordinatorState (..),
    TransactionDescriptor (..),
    TransactionError,
    TransactionRecord (..),
    TransactionTarget,
    TxnKind (..),
    coordinatorKey,
    encodeCoordinator,
    operationTransactionTarget,
    projectTransactionTarget,
    readTransactionRecord,
    sessionTransactionTarget,
    stampTarget,
    transactionErrorMessage,
 )
