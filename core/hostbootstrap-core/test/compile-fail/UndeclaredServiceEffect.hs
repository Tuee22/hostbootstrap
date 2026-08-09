{-# LANGUAGE DataKinds #-}

{- | A role may perform only the effects its declared row names (§ AA).

'HasEffect' has no @'[]@ equation on purpose, so demanding an effect a row does
not carry is an unsolved constraint rather than a runtime refusal. This fixture
is the proof of that: @listenOnly@ declares network-listen alone, and asking it
to satisfy a durable-store requirement must not compile.

The permitted direction is exercised in @RoleLifecycleSpec@; only the refusal
belongs here.
-}
module UndeclaredServiceEffect where

import HostBootstrap.RoleLifecycle

-- | Stands in for a 'ServiceProgram' constructor that writes durable state.
needsDurableStore :: (HasEffect 'DurableStore effects) => DeclaredEffects effects -> ()
needsDurableStore _ = ()

-- | A row that declares one effect, and it is not the durable store.
listenOnly :: DeclaredEffects '[ 'NetworkListen]
listenOnly = WithEffect NetworkListenName NoEffects

undeclared :: ()
undeclared = needsDurableStore listenOnly
