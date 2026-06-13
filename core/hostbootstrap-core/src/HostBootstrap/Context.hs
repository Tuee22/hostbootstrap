{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Runtime binary-context configuration.
--
-- A project binary reads @project-binary-context-config.dhall@ from next to the
-- executable before normal command dispatch. This module provides the typed
-- Dhall shape, sibling-file discovery, validation, and command-gating helpers
-- used by the core and project command trees.
module HostBootstrap.Context
  ( BinaryContext (..),
    Capability (..),
    CommandClass (..),
    ContextFrame (..),
    ContextKind (..),
    ContextRequirement (..),
    ResourceEnvelope (..),
    BinaryContextError (..),
    contextFileName,
    defaultResourceEnvelope,
    contextPathForExecutable,
    siblingContextPath,
    hostOrchestratorContext,
    deriveVMContext,
    deriveContainerContext,
    deriveServiceContext,
    standaloneContainerContext,
    contextRequirement,
    decodeContextText,
    decodeContextFile,
    readContextFile,
    renderContext,
    writeContextFile,
    validateContext,
    commandAllowed,
    readAndValidateContextFile,
    requireContextFile,
    requireSiblingContext,
    withValidatedContext,
    withSiblingContext,
    contextErrorMessage,
  )
where

import Control.Exception (SomeException, try)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Dhall (FromDhall, ToDhall, auto, inputFile)
import qualified Dhall
import qualified Dhall.Core
import Dhall.Marshal.Encode (Encoder (embed))
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)

-- | The canonical sibling runtime-context filename.
contextFileName :: FilePath
contextFileName = "project-binary-context-config.dhall"

-- | A build-time placeholder for bootstrap-only context creation surfaces, such
-- as the Dockerfile shortcut, that run before a parent context is available.
-- Normal derived contexts carry the parent envelope forward.
defaultResourceEnvelope :: ResourceEnvelope
defaultResourceEnvelope = ResourceEnvelope {cpu = 0, memory = "0GiB", storage = "0GiB"}

-- | Where a context file lives for a known executable path.
contextPathForExecutable :: FilePath -> FilePath
contextPathForExecutable exe = takeDirectory exe </> contextFileName

-- | The context path for the currently running executable.
siblingContextPath :: IO FilePath
siblingContextPath = contextPathForExecutable <$> getExecutablePath

-- | The place this process occupies in the composed topology.
data ContextKind
  = HostOrchestrator
  | VMOrchestrator
  | VMProjectContainer
  | ClusterService
  | Daemon
  | OneShotJob
  | TestHarness
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | A local capability the context claims and command gates may require.
data Capability
  = HostTools
  | IncusProvider
  | DockerSocket
  | ContainerRuntime
  | KubernetesAPI
  | KindNetwork
  | DurableStore
  | ServicePort
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | A coarse command family used by the context gate.
data CommandClass
  = EnsureCommand
  | ConfigInspectionCommand
  | ConfigGenerationCommand
  | ContextCreationCommand
  | ClusterLifecycleCommand
  | TestWorkflowCommand
  | CheckCodeCommand
  | HostOrchestratorCommand
  | DaemonCommand
  | ServiceCommand
  | ProjectCommand
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | One parent frame in the global lift chain.
data ContextFrame = ContextFrame
  { frameKind :: ContextKind,
    frameBinary :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The resource envelope this context is inside.
data ResourceEnvelope = ResourceEnvelope
  { cpu :: Natural,
    memory :: Text,
    storage :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Runtime context read by a project binary before normal command dispatch.
data BinaryContext = BinaryContext
  { project :: Text,
    binary :: Text,
    sourceRoot :: Text,
    contextKind :: ContextKind,
    parentChain :: [ContextFrame],
    capabilities :: [Capability],
    allowedCommandClasses :: [CommandClass],
    resourceEnvelope :: ResourceEnvelope,
    childContextKinds :: [ContextKind]
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Construct the first context created by the Python bootstrapper.
hostOrchestratorContext :: Text -> Text -> Text -> ResourceEnvelope -> BinaryContext
hostOrchestratorContext projectName binaryName root envelope =
  BinaryContext
    { project = projectName,
      binary = binaryName,
      sourceRoot = root,
      contextKind = HostOrchestrator,
      parentChain = [],
      capabilities = [HostTools, IncusProvider],
      allowedCommandClasses =
        [ EnsureCommand,
          ConfigInspectionCommand,
          ConfigGenerationCommand,
          ContextCreationCommand,
          ClusterLifecycleCommand,
          TestWorkflowCommand,
          CheckCodeCommand,
          HostOrchestratorCommand,
          ProjectCommand
        ],
      resourceEnvelope = envelope,
      childContextKinds =
        [ VMOrchestrator,
          VMProjectContainer,
          ClusterService,
          Daemon,
          OneShotJob,
          TestHarness
        ]
    }

-- | Derive a VM-local orchestrator context from its parent.
deriveVMContext :: BinaryContext -> Text -> BinaryContext
deriveVMContext parent root =
  childContext
    parent
    root
    VMOrchestrator
    [HostTools, DockerSocket, ContainerRuntime]
    [EnsureCommand, ConfigInspectionCommand, ConfigGenerationCommand, ContextCreationCommand, ClusterLifecycleCommand, TestWorkflowCommand, CheckCodeCommand, ProjectCommand]
    [VMProjectContainer, ClusterService, Daemon, OneShotJob, TestHarness]

-- | Derive a project-container context from its parent.
deriveContainerContext :: BinaryContext -> Text -> BinaryContext
deriveContainerContext parent root =
  childContext
    parent
    root
    VMProjectContainer
    [DockerSocket, ContainerRuntime, KindNetwork]
    [ConfigInspectionCommand, ConfigGenerationCommand, ContextCreationCommand, ClusterLifecycleCommand, TestWorkflowCommand, CheckCodeCommand, ProjectCommand]
    [ClusterService, OneShotJob, TestHarness]

-- | Derive a cluster-service context from its parent.
deriveServiceContext :: BinaryContext -> Text -> BinaryContext
deriveServiceContext parent root =
  childContext
    parent
    root
    ClusterService
    [KubernetesAPI, DurableStore, ServicePort]
    [ConfigInspectionCommand, ServiceCommand]
    []

-- | Create a standalone project-container context for Dockerfile bootstrap
-- surfaces such as @--create-container-config@, which run before normal command
-- gating can require an existing sibling context.
standaloneContainerContext :: Text -> Text -> Text -> ResourceEnvelope -> BinaryContext
standaloneContainerContext projectName binaryName root envelope =
  BinaryContext
    { project = projectName,
      binary = binaryName,
      sourceRoot = root,
      contextKind = VMProjectContainer,
      parentChain = [],
      capabilities = [DockerSocket, ContainerRuntime, KindNetwork],
      allowedCommandClasses =
        [ ConfigInspectionCommand,
          ConfigGenerationCommand,
          ContextCreationCommand,
          ClusterLifecycleCommand,
          TestWorkflowCommand,
          CheckCodeCommand,
          ProjectCommand
        ],
      resourceEnvelope = envelope,
      childContextKinds = [ClusterService, OneShotJob, TestHarness]
    }

childContext ::
  BinaryContext ->
  Text ->
  ContextKind ->
  [Capability] ->
  [CommandClass] ->
  [ContextKind] ->
  BinaryContext
childContext parent root kind caps classes childKinds =
  BinaryContext
    { project = project parent,
      binary = binary parent,
      sourceRoot = root,
      contextKind = kind,
      parentChain = parentChain parent ++ [ContextFrame (contextKind parent) (binary parent)],
      capabilities = caps,
      allowedCommandClasses = classes,
      resourceEnvelope = resourceEnvelope parent,
      childContextKinds = childKinds
    }

-- | What a command expects from the active context.
data ContextRequirement = ContextRequirement
  { requiredProject :: Text,
    requiredBinary :: Text,
    requiredCommandClass :: CommandClass,
    requiredCapabilities :: [Capability]
  }
  deriving (Eq, Show)

-- | The standard project-binary requirement shape. The current CLI entrypoint
-- uses one program name for both the project and binary identity.
contextRequirement :: Text -> CommandClass -> [Capability] -> ContextRequirement
contextRequirement binaryName commandClass caps =
  ContextRequirement
    { requiredProject = binaryName,
      requiredBinary = binaryName,
      requiredCommandClass = commandClass,
      requiredCapabilities = caps
    }

-- | Fail-fast context loading and validation errors.
data BinaryContextError
  = ContextMissing FilePath
  | ContextDecodeFailed FilePath String
  | ContextProjectMismatch Text Text
  | ContextBinaryMismatch Text Text
  | ContextCommandNotAllowed CommandClass ContextKind
  | ContextCapabilityMissing Capability
  deriving (Eq, Show)

-- | Decode a context from Dhall source text. Throws a Dhall exception on
-- malformed or ill-typed input.
decodeContextText :: Text -> IO BinaryContext
decodeContextText = Dhall.input auto

-- | Decode a context from a Dhall file. Throws a Dhall exception on malformed
-- or ill-typed input.
decodeContextFile :: FilePath -> IO BinaryContext
decodeContextFile = inputFile auto

-- | Read a context file, returning structured errors instead of throwing.
readContextFile :: FilePath -> IO (Either BinaryContextError BinaryContext)
readContextFile path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left (ContextMissing path))
    else do
      result <- try (decodeContextFile path) :: IO (Either SomeException BinaryContext)
      pure $ case result of
        Left err -> Left (ContextDecodeFailed path (show err))
        Right ctx -> Right ctx

-- | Render a context to Dhall source text.
renderContext :: BinaryContext -> Text
renderContext ctx = Dhall.Core.pretty (embed (Dhall.inject :: Encoder BinaryContext) ctx)

-- | Write a context file.
writeContextFile :: FilePath -> BinaryContext -> IO ()
writeContextFile path ctx = TIO.writeFile path (renderContext ctx <> "\n")

-- | Check whether a command class is allowed by the context.
commandAllowed :: BinaryContext -> CommandClass -> Bool
commandAllowed ctx cls = cls `elem` allowedCommandClasses ctx

-- | Validate a decoded context against a command's requirements.
validateContext :: ContextRequirement -> BinaryContext -> Either BinaryContextError BinaryContext
validateContext req ctx
  | project ctx /= requiredProject req =
      Left (ContextProjectMismatch (requiredProject req) (project ctx))
  | binary ctx /= requiredBinary req =
      Left (ContextBinaryMismatch (requiredBinary req) (binary ctx))
  | not (commandAllowed ctx (requiredCommandClass req)) =
      Left (ContextCommandNotAllowed (requiredCommandClass req) (contextKind ctx))
  | Just missing <- find (`notElem` capabilities ctx) (requiredCapabilities req) =
      Left (ContextCapabilityMissing missing)
  | otherwise = Right ctx

-- | Load and validate a context file.
readAndValidateContextFile :: FilePath -> ContextRequirement -> IO (Either BinaryContextError BinaryContext)
readAndValidateContextFile path req = do
  loaded <- readContextFile path
  pure (loaded >>= validateContext req)

-- | Load and validate a context file, exiting with status 1 on failure.
requireContextFile :: FilePath -> ContextRequirement -> IO BinaryContext
requireContextFile path req = do
  result <- readAndValidateContextFile path req
  case result of
    Right ctx -> pure ctx
    Left err -> do
      hPutStrLn stderr (contextErrorMessage err)
      exitWith (ExitFailure 1)

-- | Load and validate the currently running executable's sibling context.
requireSiblingContext :: Text -> CommandClass -> [Capability] -> IO BinaryContext
requireSiblingContext binaryName cls caps = do
  path <- siblingContextPath
  requireContextFile path (contextRequirement binaryName cls caps)

-- | Run an action only when the decoded context satisfies the command
-- requirement. This keeps command tests side-effect-free on gate failure.
withValidatedContext :: BinaryContext -> ContextRequirement -> IO a -> IO (Either BinaryContextError a)
withValidatedContext ctx req action =
  case validateContext req ctx of
    Left err -> pure (Left err)
    Right _ -> Right <$> action

-- | Run an action with the validated sibling context.
withSiblingContext :: Text -> CommandClass -> [Capability] -> (BinaryContext -> IO a) -> IO a
withSiblingContext binaryName cls caps action = do
  ctx <- requireSiblingContext binaryName cls caps
  action ctx

-- | A one-line diagnostic suitable for fail-fast CLI exits.
contextErrorMessage :: BinaryContextError -> String
contextErrorMessage err =
  case err of
    ContextMissing path ->
      "binary context: missing " ++ path
    ContextDecodeFailed path detail ->
      "binary context: failed to decode " ++ path ++ ": " ++ firstLine detail
    ContextProjectMismatch expected actual ->
      "binary context: project mismatch (expected " ++ txt expected ++ ", got " ++ txt actual ++ ")"
    ContextBinaryMismatch expected actual ->
      "binary context: binary mismatch (expected " ++ txt expected ++ ", got " ++ txt actual ++ ")"
    ContextCommandNotAllowed cls kind ->
      "binary context: command " ++ show cls ++ " is not allowed in " ++ show kind
    ContextCapabilityMissing cap ->
      "binary context: missing capability " ++ show cap
  where
    txt = T.unpack
    firstLine = takeWhile (/= '\n')
