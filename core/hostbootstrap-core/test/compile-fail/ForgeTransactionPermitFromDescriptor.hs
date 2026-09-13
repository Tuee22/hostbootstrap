module ForgeTransactionPermitFromDescriptor where

-- The seam that describes the durable state an interrupted transaction leaves
-- is not on the public library surface. Its types mint no authority, but the
-- bytes they render are the coordinator's own, so a downstream consumer that
-- could write them could put the store into a state no run produced. It lives
-- in a private sublibrary, which is the same reason and the same shape as the
-- direct-provider testing seam.
--
-- A descriptor is a description of work and never permission to perform it,
-- which is why nothing here reaches a permit — but a consumer cannot reach the
-- descriptor either, and that is what this fixture pins.
import HostBootstrap.Lifecycle.Session.Testing (
    TransactionDescriptor (..),
    TxnKind (TxnOpenProject),
 )

forgedPermit =
    TransactionDescriptor
        { descriptorSequence = 1
        , descriptorPlan = "plan"
        , descriptorKind = TxnOpenProject
        , descriptorTargets = []
        }
