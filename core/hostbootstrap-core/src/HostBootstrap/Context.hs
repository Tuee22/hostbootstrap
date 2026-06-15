{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Runtime binary-context configuration.
--
-- A project binary reads a project-local @<project>.dhall@ before normal
-- command dispatch; this module provides the typed context section embedded in
-- that file plus validation helpers used by the command gate.
module HostBootstrap.Context
  ( BinaryContext (..),
    Capability (..),
    CommandClass (..),
    ContextFrame (..),
    ContextKind (..),
    ContextRequirement (..),
    ResourceEnvelope (..),
    BinaryContextError (..),
    defaultResourceEnvelope,
    defaultRoleName,
    contextForKind,
    hostOrchestratorContext,
    deriveVMContext,
    deriveContainerContext,
    deriveServiceContext,
    deriveDaemonContext,
    deriveOneShotContext,
    deriveTestHarnessContext,
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
    withValidatedContext,
    contextErrorMessage,
    vocabUnions,
  )
where

import Control.Exception (SomeException, try)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Dhall (FromDhall, ToDhall, auto, inputFile)
import qualified Dhall
import GHC.Generics (Generic)
import HostBootstrap.Dhall.Hoist (NamedUnion)
import qualified HostBootstrap.Dhall.Hoist as Hoist
import Numeric.Natural (Natural)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hPutStrLn, stderr)

-- | A build-time placeholder for bootstrap-only config initialization surfaces
-- that run before a parent context is available. Normal derived contexts carry
-- the parent envelope forward.
defaultResourceEnvelope :: ResourceEnvelope
defaultResourceEnvelope = ResourceEnvelope {cpu = 0, memory = "0GiB", storage = "0GiB"}

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
    roleName :: Text,
    parentChain :: [ContextFrame],
    capabilities :: [Capability],
    allowedCommandClasses :: [CommandClass],
    resourceEnvelope :: ResourceEnvelope,
    childContextKinds :: [ContextKind]
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Construct a standalone context of the requested kind. Parent-generated
-- child contexts use the same role-specific authority, plus a parent frame.
contextForKind :: Text -> Text -> Text -> ResourceEnvelope -> ContextKind -> BinaryContext
contextForKind projectName binaryName root envelope kind =
  BinaryContext
    { project = projectName,
      binary = binaryName,
      sourceRoot = root,
      contextKind = kind,
      roleName = defaultRoleName kind,
      parentChain = [],
      capabilities = capabilitiesForKind kind,
      allowedCommandClasses = commandClassesForKind kind,
      resourceEnvelope = envelope,
      childContextKinds = childKindsForKind kind
    }

-- | Construct a host-orchestrator context.
hostOrchestratorContext :: Text -> Text -> Text -> ResourceEnvelope -> BinaryContext
hostOrchestratorContext projectName binaryName root envelope =
  contextForKind projectName binaryName root envelope HostOrchestrator

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
    (capabilitiesForKind ClusterService)
    (commandClassesForKind ClusterService)
    (childKindsForKind ClusterService)

-- | Derive a daemon context from its parent.
deriveDaemonContext :: BinaryContext -> Text -> BinaryContext
deriveDaemonContext parent root =
  childContext
    parent
    root
    Daemon
    (capabilitiesForKind Daemon)
    (commandClassesForKind Daemon)
    (childKindsForKind Daemon)

-- | Derive a one-shot-job context from its parent.
deriveOneShotContext :: BinaryContext -> Text -> BinaryContext
deriveOneShotContext parent root =
  childContext
    parent
    root
    OneShotJob
    (capabilitiesForKind OneShotJob)
    (commandClassesForKind OneShotJob)
    (childKindsForKind OneShotJob)

-- | Derive a test-harness context from its parent.
deriveTestHarnessContext :: BinaryContext -> Text -> BinaryContext
deriveTestHarnessContext parent root =
  childContext
    parent
    root
    TestHarness
    (capabilitiesForKind TestHarness)
    (commandClassesForKind TestHarness)
    (childKindsForKind TestHarness)

-- | Create a standalone project-container context for Dockerfile bootstrap
-- surfaces such as @config init --role vm-project-container@, which run before
-- normal command gating can require an existing sibling config.
standaloneContainerContext :: Text -> Text -> Text -> ResourceEnvelope -> BinaryContext
standaloneContainerContext projectName binaryName root envelope =
  contextForKind projectName binaryName root envelope VMProjectContainer

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
      roleName = defaultRoleName kind,
      parentChain = parentChain parent ++ [ContextFrame (contextKind parent) (binary parent)],
      capabilities = caps,
      allowedCommandClasses = classes,
      resourceEnvelope = resourceEnvelope parent,
      childContextKinds = childKinds
    }

capabilitiesForKind :: ContextKind -> [Capability]
capabilitiesForKind HostOrchestrator = [HostTools, IncusProvider]
capabilitiesForKind VMOrchestrator = [HostTools, DockerSocket, ContainerRuntime]
capabilitiesForKind VMProjectContainer = [DockerSocket, ContainerRuntime, KindNetwork]
capabilitiesForKind ClusterService = [KubernetesAPI, DurableStore, ServicePort]
capabilitiesForKind Daemon = [DurableStore, ServicePort]
capabilitiesForKind OneShotJob = [ContainerRuntime]
capabilitiesForKind TestHarness = [DockerSocket, ContainerRuntime, KindNetwork]

commandClassesForKind :: ContextKind -> [CommandClass]
commandClassesForKind HostOrchestrator =
  [ EnsureCommand,
    ConfigInspectionCommand,
    ConfigGenerationCommand,
    ContextCreationCommand,
    ClusterLifecycleCommand,
    TestWorkflowCommand,
    CheckCodeCommand,
    HostOrchestratorCommand,
    ProjectCommand
  ]
commandClassesForKind VMOrchestrator =
  [EnsureCommand, ConfigInspectionCommand, ConfigGenerationCommand, ContextCreationCommand, ClusterLifecycleCommand, TestWorkflowCommand, CheckCodeCommand, ProjectCommand]
commandClassesForKind VMProjectContainer =
  [ConfigInspectionCommand, ConfigGenerationCommand, ContextCreationCommand, ClusterLifecycleCommand, TestWorkflowCommand, CheckCodeCommand, ProjectCommand]
commandClassesForKind ClusterService =
  [ConfigInspectionCommand, ServiceCommand]
commandClassesForKind Daemon =
  [ConfigInspectionCommand, DaemonCommand]
commandClassesForKind OneShotJob =
  [ConfigInspectionCommand, ProjectCommand]
commandClassesForKind TestHarness =
  [ConfigInspectionCommand, ConfigGenerationCommand, ClusterLifecycleCommand, TestWorkflowCommand]

childKindsForKind :: ContextKind -> [ContextKind]
childKindsForKind HostOrchestrator =
  [ VMOrchestrator,
    VMProjectContainer,
    ClusterService,
    Daemon,
    OneShotJob,
    TestHarness
  ]
childKindsForKind VMOrchestrator =
  [VMProjectContainer, ClusterService, Daemon, OneShotJob, TestHarness]
childKindsForKind VMProjectContainer =
  [ClusterService, Daemon, OneShotJob, TestHarness]
childKindsForKind ClusterService = []
childKindsForKind Daemon = []
childKindsForKind OneShotJob = []
childKindsForKind TestHarness = [ClusterService]

-- | The default stable role label used in generated configs and logs.
defaultRoleName :: ContextKind -> Text
defaultRoleName HostOrchestrator = "host-orchestrator"
defaultRoleName VMOrchestrator = "vm-orchestrator"
defaultRoleName VMProjectContainer = "vm-project-container"
defaultRoleName ClusterService = "cluster-service"
defaultRoleName Daemon = "daemon"
defaultRoleName OneShotJob = "one-shot-job"
defaultRoleName TestHarness = "test-harness"

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

-- | The vocabulary unions hoisted into top-level @let@ bindings when rendering a
-- context or the project config that embeds it. Shared so both renderers
-- de-duplicate the same unions (see "HostBootstrap.Dhall.Hoist").
vocabUnions :: [NamedUnion]
vocabUnions =
  [ Hoist.unionOf @ContextKind "ContextKind",
    Hoist.unionOf @Capability "Capability",
    Hoist.unionOf @CommandClass "CommandClass"
  ]

-- | Render a context to Dhall source text, hoisting the repeated vocabulary
-- unions into top-level @let@ bindings.
renderContext :: BinaryContext -> Text
renderContext = Hoist.renderHoisted vocabUnions

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

-- | Run an action only when the decoded context satisfies the command
-- requirement. This keeps command tests side-effect-free on gate failure.
withValidatedContext :: BinaryContext -> ContextRequirement -> IO a -> IO (Either BinaryContextError a)
withValidatedContext ctx req action =
  case validateContext req ctx of
    Left err -> pure (Left err)
    Right _ -> Right <$> action

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
