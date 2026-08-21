{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

{- | The closed, effect-indexed program a service handler returns (§ AA).

A handler used to return @IO ()@: its input was least-authority but what it could
*do* was not, so a web role could spawn a process and an accelerator role could
reopen the sibling config.  This is the type that removes that.

Three things are unrepresentable here rather than checked:

* __an effect the role did not declare__ — every effectful constructor carries
  @'HasEffect' e effects@, and 'HostBootstrap.RoleLifecycle.HasEffect' has no
  empty-row equation, so the compiler names the effect and the row;
* __an effect outside the signed ceiling__ — the only eliminator,
  'interpretServiceProgram', demands the
  'HostBootstrap.RoleLifecycle.EffectAuthorization' whose sole producer compares
  the declared row against the placement's signed @permittedEffects@;
* __an effect that is not one of the four families__ — the constructors are
  private and there is no @IO@, @MonadIO@, @liftIO@, or file/socket constructor.
  A project builds a program only through the smart constructors below and the
  'Monad' instance, and cannot pattern-match one, so it can neither inject an
  effect nor write a second interpreter that skips the gate.

__Who performs an effect.__  @hostbootstrap-core@ has no @wai@, @warp@, or
@network@ dependency and must not acquire one: a project owns its own HTTP and
worker stack.  So the split is by what core can actually hold.

* 'DurableStore' is __core-executed__.  A 'DurablePath' is minted only from the
  admitted canonical project root through
  'HostBootstrap.ProjectRoot.canonicalHostSubPath', so a handler cannot name a
  path outside its own durable root — there is no way to spell @..@ past it.
* The three families core cannot hold reach a 'ServiceBackend', the same plain
  effect boundary 'HostBootstrap.Substrate.Provider.Alias.GuestExec' already is:
  a boundary, not authority.  Core still owns the program, the row, the
  authorization, and the interpreter loop.

__Handles are not names.__  A listener, peer, or worker argument is an
'AcquiredResource', whose sole producer is the engine's Ready phase.  A handler
therefore cannot bind, connect, or spawn — it can only act on something the
engine already acquired and probed, which is § AA's "Serve has no
handler-visible open/bind/spawn escape hatch".
-}
module HostBootstrap.Service.Program (
    -- * What a project's payload family is
    ServicePayloads (..),

    -- * Resources the engine acquired
    AcquiredResource,
    acquiredResourceName,
    ReadyServiceHandles,
    readyServiceHandles,
    readyServiceHandleNames,
    lookupAcquiredResource,

    -- * The durable root a role may reach
    DurablePath,
    durablePathValue,
    durablePathSegments,
    serviceDurablePath,

    -- * The program
    ServiceProgram,
    serve,
    call,
    readDurable,
    writeDurable,
    work,

    -- * The injected effect boundary
    ServiceBackend (..),

    -- * The sole eliminator
    ServiceProgramError (..),
    EffectFailure (..),
    serviceProgramErrorMessage,
    interpretServiceProgram,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Kind (Type)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.ProjectRoot (
    CanonicalHostPath,
    CanonicalProjectRoot,
    ProjectRootError,
    canonicalHostPathValue,
    canonicalHostSubPath,
 )
import HostBootstrap.RoleLifecycle (
    EffectAuthorization,
    HasEffect,
    RoleEffect (..),
    roleEffectName,
 )
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)

-- ---------------------------------------------------------------------------
-- The project's payload family

{- | The payload types one project's service stack uses.

They are gathered under a __single__ @payload@ index rather than spread across
four independent type parameters, and that is the point: a program and the
backend that runs it agree by one type equality instead of four coincidences,
and a caller cannot collapse two families by instantiating them to the same
type.  A listener application from one project's stack therefore cannot be run
by another's backend.
-}
class ServicePayloads (payload :: Type) where
    -- | What runs on an acquired listener.
    type ListenApp payload

    -- | What is sent to an acquired peer, and what comes back.
    type CallRequest payload
    type CallReply payload

    -- | What is asked of an acquired worker, and what comes back.
    type WorkRequest payload
    type WorkReply payload

-- ---------------------------------------------------------------------------
-- Acquired resources

{- | One resource the engine acquired and Ready probed.

Its constructor is private and 'readyServiceHandles' is the sole producer, so a
handler cannot name a resource the engine never acquired.  The @service@ index is
shared with the program, so one role's handles cannot be used by another's.
-}
newtype AcquiredResource service = AcquiredResource Text
    deriving (Eq)

instance Show (AcquiredResource service) where
    show (AcquiredResource name) = "AcquiredResource " <> show name

acquiredResourceName :: AcquiredResource service -> Text
acquiredResourceName (AcquiredResource name) = name

{- | The exact set of resources Serve may use.  Read-only: there is no insert,
so the set a handler sees is the one Acquire created and Ready probed.
-}
newtype ReadyServiceHandles service = ReadyServiceHandles [AcquiredResource service]

{- | The sole producer.  Package-internal in effect: only the role engine calls
it, with the names its own Ready phase probed.
-}
readyServiceHandles :: [Text] -> ReadyServiceHandles service
readyServiceHandles names = ReadyServiceHandles (map AcquiredResource names)

readyServiceHandleNames :: ReadyServiceHandles service -> [Text]
readyServiceHandleNames (ReadyServiceHandles handles) = map acquiredResourceName handles

{- | Look one acquired resource up by the name the role plan declared.

'Nothing' means the engine did not acquire it, which a handler must treat as a
refusal rather than proceeding — there is no other way to obtain the token.
-}
lookupAcquiredResource ::
    ReadyServiceHandles service ->
    Text ->
    Maybe (AcquiredResource service)
lookupAcquiredResource (ReadyServiceHandles handles) name =
    case filter ((== name) . acquiredResourceName) handles of
        (handle : _) -> Just handle
        [] -> Nothing

-- ---------------------------------------------------------------------------
-- The durable root

{- | A path inside the role's own durable root.

Its constructor is private and 'serviceDurablePath' is the sole producer, which
goes through 'canonicalHostSubPath' — so every segment is a single ordinary
component and a handler cannot spell its way out of the root with @..@, an
absolute path, or an embedded separator.  This is why 'DurableStore' can be
core-executed: core is not trusting the handler with a 'FilePath'.
-}
data DurablePath service = DurablePath CanonicalHostPath' [Text]

-- | The erased canonical path, so this module needs no scope indices of its own.
newtype CanonicalHostPath' = CanonicalHostPath' FilePath

durablePathValue :: DurablePath service -> FilePath
durablePathValue (DurablePath (CanonicalHostPath' path) _) = path

-- | The segments the path was minted from, for diagnostics.
durablePathSegments :: DurablePath service -> [Text]
durablePathSegments (DurablePath _ segments) = segments

{- | Mint a durable path under the role's admitted root.  Refuses any segment
that is not a single ordinary component.
-}
serviceDurablePath ::
    CanonicalProjectRoot rootScope rootId ->
    -- | the durable root's own segments, e.g. @[".test_data", "run-42"]@
    [FilePath] ->
    -- | the path within it
    [Text] ->
    Either ProjectRootError (DurablePath service)
serviceDurablePath root rootSegments segments = do
    resolved <- canonicalHostSubPath root (rootSegments ++ map Text.unpack segments)
    pure (DurablePath (CanonicalHostPath' (canonicalHostPathValue' resolved)) segments)
  where
    canonicalHostPathValue' :: CanonicalHostPath rootScope rootId -> FilePath
    canonicalHostPathValue' = canonicalHostPathValue

-- ---------------------------------------------------------------------------
-- The program

{- | A service handler's whole program.

The constructors are private.  A project builds one only through the smart
constructors and the 'Monad' instance, so it cannot pattern-match a program,
cannot write a second interpreter that skips the authorization gate, and cannot
add a constructor of its own.
-}
data ServiceProgram payload service (effects :: [RoleEffect]) a where
    Done :: a -> ServiceProgram payload service effects a
    Then ::
        ServiceProgram payload service effects a ->
        (a -> ServiceProgram payload service effects b) ->
        ServiceProgram payload service effects b
    Serve ::
        (HasEffect 'NetworkListen effects) =>
        [(AcquiredResource service, ListenApp payload)] ->
        ServiceProgram payload service effects ()
    Call ::
        (HasEffect 'NetworkConnect effects) =>
        AcquiredResource service ->
        CallRequest payload ->
        ServiceProgram payload service effects (CallReply payload)
    ReadDurable ::
        (HasEffect 'DurableStore effects) =>
        DurablePath service ->
        ServiceProgram payload service effects (Maybe ByteString)
    WriteDurable ::
        (HasEffect 'DurableStore effects) =>
        DurablePath service ->
        ByteString ->
        ServiceProgram payload service effects ()
    Work ::
        (HasEffect 'ProcessSpawn effects) =>
        AcquiredResource service ->
        WorkRequest payload ->
        ServiceProgram payload service effects (WorkReply payload)

instance Functor (ServiceProgram payload service effects) where
    fmap f program = Then program (Done . f)

instance Applicative (ServiceProgram payload service effects) where
    pure = Done
    left <*> right = Then left (\f -> Then right (Done . f))

{- | Sequencing only.  There is deliberately no 'Control.Monad.IO.Class.MonadIO'
instance: an @IO@ escape hatch would make every guarantee above vacuous.
-}
instance Monad (ServiceProgram payload service effects) where
    (>>=) = Then

{- | Run applications on acquired listeners, as one lifetime.

Taking the whole set at once is what lets a backend supervise them together — a
role whose private ingress dies must not keep serving its public port — without
a concurrency constructor a handler could misuse.
-}
serve ::
    (HasEffect 'NetworkListen effects) =>
    [(AcquiredResource service, ListenApp payload)] ->
    ServiceProgram payload service effects ()
serve = Serve

-- | Send one request to an acquired peer.
call ::
    (HasEffect 'NetworkConnect effects) =>
    AcquiredResource service ->
    CallRequest payload ->
    ServiceProgram payload service effects (CallReply payload)
call = Call

-- | Read one path inside the role's own durable root.
readDurable ::
    (HasEffect 'DurableStore effects) =>
    DurablePath service ->
    ServiceProgram payload service effects (Maybe ByteString)
readDurable = ReadDurable

-- | Write one path inside the role's own durable root.
writeDurable ::
    (HasEffect 'DurableStore effects) =>
    DurablePath service ->
    ByteString ->
    ServiceProgram payload service effects ()
writeDurable = WriteDurable

-- | Ask an acquired worker for one unit of work.
work ::
    (HasEffect 'ProcessSpawn effects) =>
    AcquiredResource service ->
    WorkRequest payload ->
    ServiceProgram payload service effects (WorkReply payload)
work = Work

-- ---------------------------------------------------------------------------
-- The injected effect boundary

{- | How the three families core cannot hold reach the world.

This is a plain effect handle, not authority — the same boundary
'HostBootstrap.Substrate.Provider.Alias.GuestExec' is.  Core decides *whether* an
effect may run; the backend is *how* it runs.  Its @payload@ index is the
program's, so a backend cannot execute another project's program.

There is no durable-store member: core executes that family itself against a
'DurablePath', because it can, and because doing so is what keeps a handler from
naming a path outside its own root.
-}
data ServiceBackend payload = ServiceBackend
    { backendServe :: [(Text, ListenApp payload)] -> IO (Either Text ())
    , backendCall :: Text -> CallRequest payload -> IO (Either Text (CallReply payload))
    , backendWork :: Text -> WorkRequest payload -> IO (Either Text (WorkReply payload))
    }

-- ---------------------------------------------------------------------------
-- The eliminator

{- | The only way a program fails: an effect the backend could not perform.

There is deliberately no "unauthorized effect" constructor. A row a program is
indexed by and the row its authorization admits agree __by construction__ —
'HostBootstrap.RoleLifecycle.DeclaredEffects' is the term-level twin of the same
type-level list, and 'HostBootstrap.RoleLifecycle.authorizeServiceEffects' mints
the authorization from that one value — so a program demanding an unadmitted
effect is not a state the interpreter can observe. Carrying a branch for it would
claim the two can disagree.
-}
newtype ServiceProgramError
    = -- | the family, then what the backend reported
      ServiceEffectFailed EffectFailure
    deriving (Eq, Show)

-- | The family that failed and what its backend said.
data EffectFailure = EffectFailure Text Text
    deriving (Eq, Show)

serviceProgramErrorMessage :: ServiceProgramError -> String
serviceProgramErrorMessage (ServiceEffectFailed (EffectFailure family detail)) =
    "service program: the " <> Text.unpack family <> " effect failed: " <> Text.unpack detail

{- | The __only__ way to run a program.

It demands the 'EffectAuthorization', whose sole producer compared the declared
row against the signed ceiling, so a program cannot be run without that
comparison having happened.  The authorization is a __capability, not a lookup
table__: the interpreter never consults it, because the constraint on each
constructor already proves the effect is in the row, and the row the
authorization admits is the row the program is indexed by.  Its presence is the
whole of its job.
-}
interpretServiceProgram ::
    forall scope specDigest planId frame revision instanceId service effects payload a.
    EffectAuthorization scope specDigest planId frame revision instanceId service effects ->
    ServiceBackend payload ->
    ServiceProgram payload service effects a ->
    IO (Either ServiceProgramError a)
interpretServiceProgram _authorization backend = go
  where
    go :: ServiceProgram payload service effects b -> IO (Either ServiceProgramError b)
    go (Done value) = pure (Right value)
    go (Then program next) = do
        stepped <- go program
        case stepped of
            Left failure -> pure (Left failure)
            Right value -> go (next value)
    go (Serve pairs) =
        report (roleEffectName NetworkListen)
            <$> backendServe backend [(acquiredResourceName handle, app) | (handle, app) <- pairs]
    go (Call handle request) =
        report (roleEffectName NetworkConnect)
            <$> backendCall backend (acquiredResourceName handle) request
    go (Work handle request) =
        report (roleEffectName ProcessSpawn)
            <$> backendWork backend (acquiredResourceName handle) request
    go (ReadDurable path) = do
        let file = durablePathValue path
        present <- doesFileExist file
        if present
            then Right . Just <$> ByteString.readFile file
            else pure (Right Nothing)
    go (WriteDurable path payload) = do
        let file = durablePathValue path
        createDirectoryIfMissing True (takeDirectory file)
        ByteString.writeFile file payload
        pure (Right ())

    report :: Text -> Either Text r -> Either ServiceProgramError r
    report family = either (Left . ServiceEffectFailed . EffectFailure family) Right
