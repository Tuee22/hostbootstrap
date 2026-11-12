{- | Package-private admission for fixed-domain root signing and durable joins.

The historically named capability entered through recovery signing, but it is
not a generic byte signer.  Only allow-listed hidden owners receive the sole
value, and every facade kernel fixes its own canonical domain and typed input.
The exposed handoff facade can consume the abstract capability, but cannot
construct it or export its representation.

The registered-edge reread policy is separate descriptive DATA. It neither
consumes signing admission nor performs protected-store operations.
-}
module HostBootstrap.Handoff.Internal (
    RecoverySigningKernel,
    recoverySigningKernel,
    consumeRecoverySigningKernel,
    consumeRootedLifecycleResponseSigningKernel,
    RegisteredEdgeRereadResult (..),
    classifyRegisteredEdgeReread,
)
where

import Data.ByteString (ByteString)
import HostBootstrap.Handoff.Rooted (RootedLifecycleResponse)

-- | Nominal, unconstructible outside this Cabal-hidden module.
data RecoverySigningKernel = RecoverySigningKernel

-- | The sole package-private producer, consumed only by hidden fixed-domain owners.
recoverySigningKernel :: RecoverySigningKernel
recoverySigningKernel = RecoverySigningKernel

-- | Strictly consume the admission before exposing the gated continuation.
consumeRecoverySigningKernel :: RecoverySigningKernel -> result -> result
{-# OPAQUE consumeRecoverySigningKernel #-}
consumeRecoverySigningKernel RecoverySigningKernel result = result

-- | Admit only the fixed rooted-response signer shape through the existing capability.
consumeRootedLifecycleResponseSigningKernel ::
    RecoverySigningKernel ->
    (broker -> ByteString -> ByteString -> IO (Either failure RootedLifecycleResponse)) ->
    broker ->
    ByteString ->
    ByteString ->
    IO (Either failure RootedLifecycleResponse)
{-# OPAQUE consumeRootedLifecycleResponseSigningKernel #-}
consumeRootedLifecycleResponseSigningKernel kernel =
    consumeRecoverySigningKernel kernel

-- | Descriptive result of rereading an edge after its first-grant CAS failed.
data RegisteredEdgeRereadResult failure
    = RegisteredEdgeGranted
    | RegisteredEdgeConsumed
    | RegisteredEdgeStoreFailure failure
    deriving (Eq, Show)

-- | Classify only retained bytes and failures; this policy performs no IO.
classifyRegisteredEdgeReread ::
    ByteString ->
    ByteString ->
    failure ->
    Either failure (Maybe ByteString) ->
    RegisteredEdgeRereadResult failure
classifyRegisteredEdgeReread planned granted writeFailure reread = case reread of
    Left readFailure -> RegisteredEdgeStoreFailure readFailure
    Right Nothing -> RegisteredEdgeStoreFailure writeFailure
    Right (Just retained)
        | retained == granted -> RegisteredEdgeGranted
        | retained == planned -> RegisteredEdgeStoreFailure writeFailure
        | otherwise -> RegisteredEdgeConsumed
