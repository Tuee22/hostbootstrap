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
    inContainer,

    -- * Self-reference
    SelfRef (..),
    mkSelfRef,
    currentSelfRef,

    -- * Folding and dispatch
    LiftDispatch (..),
    foldLift,
    containerRunArgs,
    liftSubcommand,
    runSelf,
  )
where

import Control.Exception (SomeException)
import Control.Exception.Safe (try)
import qualified Data.Text as T
import HostBootstrap.Config.Vocab (Mount)
import qualified HostBootstrap.Config.Vocab as Vocab
import HostBootstrap.Ensure (runTool)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.HostTool (HostTool (Docker, Incus, Lima), toolCommandName)
import HostBootstrap.Incus (IncusVM, execVMArgs)
import HostBootstrap.Lima (LimaVM)
import qualified HostBootstrap.Lima as Lima
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
data LiftLayer = ViaVM IncusVM | ViaLimaVM LimaVM | ViaContainer ContainerLift
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

-- | Fold a context stack and a subcommand into the host invocation. Pure, so the
-- argv is unit-tested. Encodes the @§ K@ rule already implicit in 'execVMArgs':
-- only the outermost host dispatch names a tool that the resolver maps to an
-- absolute path; every nested tool is the target's own bare @$PATH@ name.
foldLift :: SelfRef -> LiftContext -> [String] -> LiftDispatch
foldLift self (LiftContext layers) sub = build layers
  where
    build [] = DispatchLocal (localSelfPath self) sub
    build (ViaVM vm : rest) = DispatchTool Incus (execVMArgs vm (insideVM rest))
    build (ViaLimaVM vm : rest) = DispatchTool Lima (Lima.shellVMArgs vm (insideVM rest))
    build (ViaContainer c : _) = DispatchTool Docker (containerRunArgs c sub)

    -- The argv to run inside a VM, given the remaining inner layers.
    insideVM [] = inVMSelfPath self : sub
    insideVM (ViaVM vm : rest) = toolCommandName Incus : execVMArgs vm (insideVM rest)
    insideVM (ViaLimaVM vm : rest) = toolCommandName Lima : Lima.shellVMArgs vm (insideVM rest)
    insideVM (ViaContainer c : _) = toolCommandName Docker : containerRunArgs c sub

-- | Run a subcommand of this binary in a context: fold to a 'LiftDispatch', then
-- exec — a host tool via 'runTool' (absolute path), or the binary itself via
-- 'runSelf'.
liftSubcommand ::
  HostConfig ->
  SelfRef ->
  LiftContext ->
  [String] ->
  IO (Either String (ExitCode, String, String))
liftSubcommand cfg self ctx sub = case foldLift self ctx sub of
  DispatchLocal exe args -> runSelf exe args
  DispatchTool tool args -> runTool cfg tool args

-- | Run a local executable (the binary itself — not a 'HostTool') capturing its
-- exit/stdout/stderr; 'Left' on an exec failure.
runSelf :: FilePath -> [String] -> IO (Either String (ExitCode, String, String))
runSelf exe args = do
  result <- try (readProcessWithExitCode exe args "")
  pure $ case (result :: Either SomeException (ExitCode, String, String)) of
    Right ok -> Right ok
    Left err -> Left ("could not exec " ++ exe ++ ": " ++ show err)
