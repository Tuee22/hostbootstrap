-- | The self-reference compositional lift: run a subcommand of /this same
-- binary/ in a nested execution context by invoking the binary again there.
--
-- This is the one foundational composition primitive (see
-- @development_plan_standards.md § U@). A deployment is ordinary @IO@ sequencing
-- of @ensure@/deploy steps; crossing a context boundary is the binary
-- re-invoking its own subcommand in the nested context — @limactl shell \<vm\> --
-- \<pb\> \<subcmd\>@ or @incus exec \<vm\> -- \<pb\> \<subcmd\>@ for a VM,
-- @docker run --rm \<image\> \<subcmd\>@ for a
-- container (whose @ENTRYPOINT@ /is/ the binary). A nested call runs the same
-- @optparse-applicative@ command tree, so each step runs "locally" in whatever
-- context it was placed in, unaware it was lifted.
--
-- Contexts compose as a stack of layers ('LiftContext'), outermost-first.
-- 'foldLift' is pure (the argv fold is unit-tested); 'liftSubcommand' is the thin
-- @IO@ seam. This is the /subcommand-level/ lift; 'HostBootstrap.HostTarget' is
-- the narrower /tool-level/ lift kept alongside it.
--
-- A container layer is terminal in the fold: its @ENTRYPOINT@ runs the binary
-- directly, so the subcommand is passed bare after the image and any deeper
-- nesting is the in-container binary's own runtime self-lift.
module HostBootstrap.Lift
  ( -- * Contexts
    LiftLayer (..),
    ContainerLift (..),
    LiftContext (..),
    localContext,
    inVM,
    inLimaVM,
    inWsl2VM,
    inContainer,

    -- * Self-reference
    SelfRef (..),
    mkSelfRef,
    currentSelfRef,

    -- * Folding and dispatch
    LiftDispatch (..),
    LiftLeaf (..),
    reachLeaf,
    foldLeaf,
    foldLift,
    containerRunArgs,
    liftLeaf,
    liftSubcommand,
    liftSubcommandWithAuth,
    runSelf,
  )
where

import Control.Exception (SomeException)
import Control.Exception.Safe (try)
import qualified Data.Text as T
import HostBootstrap.Config.Vocab (Mount)
import qualified HostBootstrap.Config.Vocab as Vocab
import HostBootstrap.Ensure (runTool, runToolWithStdin)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Docker, Incus, Lima, Wsl), toolCommandName)
import HostBootstrap.Incus (IncusVM, execVMArgs)
import HostBootstrap.Lima (LimaVM)
import qualified HostBootstrap.Lima as Lima
import HostBootstrap.Registry (RegistryAuth, registryAuthEnvVar, registryConfigPayload)
import HostBootstrap.Wsl2 (Wsl2VM)
import qualified HostBootstrap.Wsl2 as Wsl2
import System.Environment (getExecutablePath)
import System.Exit (ExitCode)
import System.Process (readProcessWithExitCode)

-- | A @docker run@ container layer: the image to run, its bind mounts, any extra
-- raw flags (e.g. a Docker-socket mount or @--network=host@), and whether to
-- pass @--rm@. The container's @ENTRYPOINT@ is the project binary, so the lifted
-- subcommand is the command tail.
data ContainerLift = ContainerLift
  { clImage :: String,
    clMounts :: [Mount],
    clExtraArgs :: [String],
    clRemoveAfter :: Bool
  }
  deriving (Eq, Show)

-- | One context-boundary layer: a VM provider or a container.
data LiftLayer = ViaVM IncusVM | ViaLimaVM LimaVM | ViaWsl2VM Wsl2VM | ViaContainer ContainerLift
  deriving (Eq, Show)

-- | A stack of context layers, outermost-first. The empty stack is the local
-- host.
newtype LiftContext = LiftContext {liftLayers :: [LiftLayer]}
  deriving (Eq, Show)

-- | The local host: run the binary directly, no lift.
localContext :: LiftContext
localContext = LiftContext []

-- | Nest a VM as the new innermost layer.
inVM :: IncusVM -> LiftContext -> LiftContext
inVM vm (LiftContext ls) = LiftContext (ls ++ [ViaVM vm])

-- | Nest a Lima VM as the new innermost layer.
inLimaVM :: LimaVM -> LiftContext -> LiftContext
inLimaVM vm (LiftContext ls) = LiftContext (ls ++ [ViaLimaVM vm])

-- | Nest a WSL2 distro as the new innermost layer.
inWsl2VM :: Wsl2VM -> LiftContext -> LiftContext
inWsl2VM vm (LiftContext ls) = LiftContext (ls ++ [ViaWsl2VM vm])

-- | Nest a container as the new innermost layer (a container is terminal).
inContainer :: ContainerLift -> LiftContext -> LiftContext
inContainer c (LiftContext ls) = LiftContext (ls ++ [ViaContainer c])

-- | How to invoke /this binary/ per context. The local path is the running
-- executable; the in-VM path is a deployment fact (e.g. the pipx/ghcup-installed
-- @\<project\>@ on the VM's @$PATH@). A container needs no path — its
-- @ENTRYPOINT@ is the binary.
data SelfRef = SelfRef
  { localSelfPath :: FilePath,
    inVMSelfPath :: FilePath
  }
  deriving (Eq, Show)

-- | Build a 'SelfRef' from explicit paths (pure; used by the unit tests).
mkSelfRef :: FilePath -> FilePath -> SelfRef
mkSelfRef localP vmP = SelfRef {localSelfPath = localP, inVMSelfPath = vmP}

-- | Resolve a 'SelfRef' for the running binary: the local path from
-- 'getExecutablePath' (@/proc/self/exe@, not @argv0@); the in-VM path supplied by
-- the caller (where its bootstrap installs the binary).
currentSelfRef :: FilePath -> IO SelfRef
currentSelfRef vmP = do
  exe <- getExecutablePath
  pure (mkSelfRef exe vmP)

-- | The resolved host invocation a lift folds down to: either run the binary
-- itself locally, or run a host tool (@incus@/@docker@) whose args encode the
-- nested invocation.
data LiftDispatch
  = DispatchLocal FilePath [String]
  | DispatchTool HostTool [String]
  deriving (Eq, Show)

-- | The @docker run@ argv for a container layer, with the in-container command as
-- the tail. Pure.
containerRunArgs :: ContainerLift -> [String] -> [String]
containerRunArgs c inner =
  ["run"]
    ++ (["--rm" | clRemoveAfter c])
    ++ concatMap mountArg (clMounts c)
    ++ clExtraArgs c
    ++ [clImage c]
    ++ inner
  where
    mountArg m =
      [ "-v",
        T.unpack (Vocab.source m)
          ++ ":"
          ++ T.unpack (Vocab.target m)
          ++ (if Vocab.readOnly m then ":ro" else "")
      ]

-- | The innermost thing a lift runs at the bottom frame: either /this binary's/
-- own subcommand (whose path differs by frame — local vs in-VM), or an arbitrary
-- fixed command run as-is in that frame (e.g. @curl …@ or @bash -lc …@). The raw
-- form lets the /same/ pure fold place a reachability probe (or any command) into
-- the correct frame, so an assertion is provider-agnostic by construction — the
-- only thing that varies across Lima and Incus is the 'LiftLayer' constructor.
data LiftLeaf
  = SelfSub SelfRef [String]
  | RawCmd [String]
  deriving (Eq, Show)

-- | A reachability-probe leaf: a quiet, bounded @curl@ of @url@. Placed in the
-- frame where the endpoint is published (the VM), it folds to
-- @incus exec \<vm\> -- curl …@ / @limactl shell \<vm\> -- curl …@, so the one
-- probe value is correct on every provider regardless of host port-forwarding.
reachLeaf :: String -> LiftLeaf
reachLeaf url = RawCmd ["curl", "-fsS", "-m", "5", "-o", "/dev/null", url]

-- | The argv to run once inside the innermost VM (no remaining layers).
leafInVMArgv :: LiftLeaf -> [String]
leafInVMArgv (SelfSub self sub) = inVMSelfPath self : sub
leafInVMArgv (RawCmd argv) = argv

-- | The command tail passed after a container image. A 'SelfSub' relies on the
-- container @ENTRYPOINT@ being the binary, so only the subcommand is passed.
leafContainerInner :: LiftLeaf -> [String]
leafContainerInner (SelfSub _ sub) = sub
leafContainerInner (RawCmd argv) = argv

-- | The dispatch when the stack is empty (run at the local host frame).
leafLocalDispatch :: LiftLeaf -> LiftDispatch
leafLocalDispatch (SelfSub self sub) = DispatchLocal (localSelfPath self) sub
leafLocalDispatch (RawCmd (exe : args)) = DispatchLocal exe args
leafLocalDispatch (RawCmd []) = DispatchLocal "" []

-- | Fold a context stack and a 'LiftLeaf' into the host invocation. Pure, so the
-- argv is unit-tested. Encodes the @§ K@ rule already implicit in 'execVMArgs':
-- only the outermost host dispatch names a tool that the resolver maps to an
-- absolute path; every nested tool is the target's own bare @$PATH@ name.
foldLeaf :: LiftContext -> LiftLeaf -> LiftDispatch
foldLeaf (LiftContext layers) leaf = build layers
  where
    build [] = leafLocalDispatch leaf
    build (ViaVM vm : rest) = DispatchTool Incus (execVMArgs vm (insideVM rest))
    build (ViaLimaVM vm : rest) = DispatchTool Lima (Lima.shellVMArgs vm (insideVM rest))
    build (ViaWsl2VM vm : rest) = DispatchTool Wsl (Wsl2.wslExecArgs (Wsl2.wsl2Distro vm) (insideVM rest))
    build (ViaContainer c : _) = DispatchTool Docker (containerRunArgs c (leafContainerInner leaf))

    -- The argv to run inside a VM, given the remaining inner layers.
    insideVM [] = leafInVMArgv leaf
    insideVM (ViaVM vm : rest) = toolCommandName Incus : execVMArgs vm (insideVM rest)
    insideVM (ViaLimaVM vm : rest) = toolCommandName Lima : Lima.shellVMArgs vm (insideVM rest)
    insideVM (ViaWsl2VM vm : rest) = toolCommandName Wsl : Wsl2.wslExecArgs (Wsl2.wsl2Distro vm) (insideVM rest)
    insideVM (ViaContainer c : _) = toolCommandName Docker : containerRunArgs c (leafContainerInner leaf)

-- | Fold a context stack and a subcommand of /this binary/ into the host
-- invocation — the 'SelfSub' special case of 'foldLeaf'.
foldLift :: SelfRef -> LiftContext -> [String] -> LiftDispatch
foldLift self ctx sub = foldLeaf ctx (SelfSub self sub)

-- | Run a 'LiftLeaf' in a context: fold to a 'LiftDispatch', then exec — a host
-- tool via 'runTool' (absolute path), or a local command via 'runSelf'.
liftLeaf ::
  HostConfig ->
  LiftContext ->
  LiftLeaf ->
  IO (Either String (ExitCode, String, String))
liftLeaf cfg ctx leaf = case foldLeaf ctx leaf of
  DispatchLocal exe args -> runSelf exe args
  DispatchTool tool args -> runTool cfg tool args

-- | Run a subcommand of this binary in a context — the 'SelfSub' special case of
-- 'liftLeaf'.
liftSubcommand ::
  HostConfig ->
  SelfRef ->
  LiftContext ->
  [String] ->
  IO (Either String (ExitCode, String, String))
liftSubcommand cfg self ctx sub = liftLeaf cfg ctx (SelfSub self sub)

-- | Run a local executable (the binary itself — not a 'HostTool') capturing its
-- exit/stdout/stderr; 'Left' on an exec failure.
runSelf :: FilePath -> [String] -> IO (Either String (ExitCode, String, String))
runSelf exe args = do
  result <- try (readProcessWithExitCode exe args "")
  pure $ case (result :: Either SomeException (ExitCode, String, String)) of
    Right ok -> Right ok
    Left err -> Left ("could not exec " ++ exe ++ ": " ++ show err)

-- | Like 'liftSubcommand', but forward a Docker Hub credential into the nested
-- context so any image pull it performs authenticates (avoiding Docker Hub's
-- unauthenticated rate limit). The credential is forwarded only over ephemeral
-- channels and is never in @argv@, never written to a persisted file, and never
-- in Dhall:
--
--   * the minimal @config.json@ payload is piped on @stdin@ to the VM shell,
--     which imports it into the 'registryAuthEnvVar' environment variable
--     (@export VAR=\"$(cat)\"@ — the value never appears in a process listing);
--   * the @docker run@ then carries @-e \<registryAuthEnvVar\>@ (the /name/ only),
--     so Docker forwards the value into the container's environment;
--   * the in-container binary's @withForwardedRegistryAuth@ consumes it once into
--     a transient @DOCKER_CONFIG@ and never persists it.
--
-- This is the supported forwarding shape — a container reached through a VM
-- (@inContainer img (inVM\/inLimaVM vm localContext)@), the worked demo's deploy
-- frame. With 'Nothing' (no host login) or any other context shape it is exactly
-- 'liftSubcommand', so pulls degrade gracefully to anonymous.
liftSubcommandWithAuth ::
  HostConfig ->
  Maybe RegistryAuth ->
  SelfRef ->
  LiftContext ->
  [String] ->
  IO (Either String (ExitCode, String, String))
liftSubcommandWithAuth cfg Nothing self ctx sub = liftSubcommand cfg self ctx sub
liftSubcommandWithAuth cfg (Just auth) self ctx sub =
  case liftLayers ctx of
    [ViaLimaVM vm, ViaContainer c] -> forward Lima (Lima.shellVMArgs vm) c
    [ViaVM vm, ViaContainer c] -> forward Incus (execVMArgs vm) c
    [ViaWsl2VM vm, ViaContainer c] -> forward Wsl (Wsl2.wslExecArgs (Wsl2.wsl2Distro vm)) c
    _ -> liftSubcommand cfg self ctx sub
  where
    forward tool vmShell c =
      let inner = toolCommandName Docker : containerRunArgs c sub
          script =
            "export "
              ++ registryAuthEnvVar
              ++ "=\"$(cat)\"; exec "
              ++ shellQuoteArgs inner
          args = vmShell ["bash", "-lc", script]
       in runToolWithStdin cfg tool args (T.unpack (registryConfigPayload auth))

-- | Single-quote each argument and join with spaces, so an argv can be embedded
-- verbatim in a @bash -lc@ script without re-splitting or glob expansion. Pure.
shellQuoteArgs :: [String] -> String
shellQuoteArgs = unwords . map quote
  where
    quote s = "'" ++ concatMap escape s ++ "'"
    escape '\'' = "'\\''"
    escape ch = [ch]
