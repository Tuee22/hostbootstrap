module ForgeSessionPermit where

import HostBootstrap.Lifecycle.Session

-- A project permit is the sole successor of one observed journal version. It
-- cannot be conjured from a number, so a caller cannot re-authorize a
-- transition whose version it already spent.
forgedPermit :: ProjectPermit scope planId
forgedPermit = ProjectPermit 1

-- A session exists only as the result of 'openOperationSession', which proved
-- the broker generation live and no older session Open.
forgedSession :: OperationSession scope planId
forgedSession = OperationSession (SessionId "session-a") "plan" 1

-- A fence epoch is minted only by the settled FenceObserved record.
forgedFence :: FenceEpoch scope planId
forgedFence = FenceEpoch 9

-- The prepared gate is the proof that the unknown phase was durably recorded
-- before the adapter ran; asserting one would skip that record.
forgedGate :: PreparedGate scope planId
forgedGate = PreparedGate "op-1" 1 1 1

-- An advance carries the sole successor permit; building one directly would let
-- a caller keep the result and the stale permit.
forgedAdvance :: OperationAdvance scope planId ()
forgedAdvance = OperationAdvance () forgedPermit
