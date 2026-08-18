module ForgeTransactionPermitFromDescriptor where

import HostBootstrap.Lifecycle.Session.Testing (
    TransactionDescriptor (..),
    TxnKind (TxnOpenProject),
 )

-- The testing surface describes the durable state an interrupted transaction
-- leaves. A description of work is not permission to perform it, so nothing
-- here reaches the coordinator's permit: a fixture holding a descriptor still
-- has to publish it through the store and let the ordinary entry point recover
-- it.
forgedPermit =
    TransactionPermit
        TransactionDescriptor
            { descriptorSequence = 1
            , descriptorPlan = "plan"
            , descriptorKind = TxnOpenProject
            , descriptorTargets = []
            }
