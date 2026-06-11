-- | The role lifecycle skeleton (Phase 14): the L0 substrate a stateless **role**
-- runs through — Load → Prereq → Acquire → Ready → Serve → Drain → Exit — with
-- consumer-injected callbacks (see
-- @documents/architecture/composition_methodology.md@).
--
-- L0 owns only the phase skeleton and the driver; the concrete bus/store
-- bindings (the message-bus subscription, the object-store fetch, the
-- batching/scheduler policy) are the consumer's callbacks — at L1 the
-- @daemon-substrate@ primitives, in the demo a filesystem stand-in. The phase
-- ordering is pure (so it is unit-tested); 'runRole' guarantees the drain runs
-- even if serving throws.
module HostBootstrap.RoleLifecycle
  ( RolePhase (..),
    rolePhases,
    RoleSpec (..),
    runRole,
  )
where

import Control.Exception.Safe (finally)

-- | The ordered lifecycle phases a role moves through.
data RolePhase = Load | Prereq | Acquire | Ready | Serve | Drain | Exit
  deriving (Eq, Show, Enum, Bounded)

-- | The phases in order (@Load@ … @Exit@). Pure.
rolePhases :: [RolePhase]
rolePhases = [minBound .. maxBound]

-- | A role: acquire its environment (the Load→Acquire phases — e.g. fetch the
-- static artifact and subscribe), serve work (the Serve phase), and drain on
-- shutdown (the Drain→Exit phases). The skeleton is L0; these callbacks are the
-- consumer's binding to its bus/store/engine.
data RoleSpec env = RoleSpec
  { roleAcquire :: IO env,
    roleServe :: env -> IO (),
    roleDrain :: env -> IO ()
  }

-- | Drive the lifecycle: acquire, serve, then drain — with the drain guaranteed
-- via 'finally' even if serving throws (a role recovers by replay/refetch, so a
-- clean drain matters).
runRole :: RoleSpec env -> IO ()
runRole spec = do
  env <- roleAcquire spec
  roleServe spec env `finally` roleDrain spec env
