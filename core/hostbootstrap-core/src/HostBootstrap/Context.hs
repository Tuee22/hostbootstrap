{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE CPP #-}
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
    ProviderKind (..),
    ResourceEnvelope (..),
    RuntimeWitness (..),
    TopologyFrame (..),
    WitnessKind (..),
    BinaryContextError (..),
    defaultResourceEnvelope,
    defaultRoleName,
    contextForKind,
    addRole,
    hostOrchestratorContext,
    deriveVMContextWithProvider,
    deriveVMContext,
    deriveContainerContext,
    deriveLinuxGpuContainerContext,
    deriveServiceContext,
    deriveDaemonContext,
    deriveHostDaemonContext,
    deriveClusterDaemonContext,
    deriveOneShotContext,
    deriveTestHarnessContext,
    imageBuildContainerContext,
    standaloneContainerContext,
    contextRequirement,
    decodeContextText,
    decodeContextFile,
    readContextFile,
    renderComposition,
    renderContext,
    writeContextFile,
    validateContext,
    validateRuntimeContext,
    commandAllowed,
    readAndValidateContextFile,
    requireContextFile,
    withValidatedContext,
    contextErrorMessage,
    vocabUnions,
  )
where

import Control.Exception (SomeException, try)
import Data.List (find, union)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Dhall (FromDhall, ToDhall, auto, inputFile)
import qualified Dhall
import GHC.Generics (Generic)
import HostBootstrap.Dhall.Hoist (NamedUnion)
import qualified HostBootstrap.Dhall.Hoist as Hoist
import Numeric.Natural (Natural)
import System.Directory (doesFileExist, findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hPutStrLn, stderr)
#ifndef mingw32_HOST_OS
import System.Posix.Files (FileStatus, getFileStatus, isSocket)
#endif

-- | A build-time placeholder for bootstrap-only config initialization surfaces
-- that run before a parent context is available. Normal derived contexts carry
-- the parent envelope forward.
defaultResourceEnvelope :: ResourceEnvelope
defaultResourceEnvelope = ResourceEnvelope {cpu = 0, memory = "0GiB", storage = "0GiB"}

-- | Render the global lift composition this context declares — the
-- 'topologyFrames' chain with the current frame highlighted — for the read-only
-- @context@ introspection command (development_plan_standards § Z). Pure, so the
-- rendering is unit-tested; @context@ performs no mutation.
renderComposition :: BinaryContext -> String
renderComposition ctx =
  unlines (header : map renderFrame (topologyFrames ctx))
  where
    cur = currentFrame ctx
    header =
      "composition ("
        ++ show (length (topologyFrames ctx))
        ++ " frames; current = "
        ++ T.unpack cur
        ++ "):"
    renderFrame f =
      mark f
        ++ T.unpack (topologyFrameId f)
        ++ "  ["
        ++ show (topologyProvider f)
        ++ " / "
        ++ show (topologyKind f)
        ++ "]"
        ++ parentNote f
    mark f
      | topologyFrameId f == cur = "  -> "
      | otherwise = "   . "
    parentNote f
      | T.null (topologyParentId f) = ""
      | otherwise = "  (parent: " ++ T.unpack (topologyParentId f) ++ ")"

-- | The place this process occupies in the composed topology.
data ContextKind
  = HostOrchestrator
  | VMOrchestrator
  | VMProjectContainer
  | ImageBuildContainer
  | ClusterService
  | Daemon
  | OneShotJob
  | TestHarness
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The provider/substrate that owns a topology frame. The graph is deliberately
-- open-ended: later providers add constructors here without changing the core
-- frame shape.
data ProviderKind
  = HostProvider
  | IncusVMProvider
  | LimaVMProvider
  | Wsl2VMProvider
  | DockerContainerProvider
  | KubernetesProvider
  | ExternalProvider
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

-- | One node in the declared execution topology.
data TopologyFrame = TopologyFrame
  { topologyFrameId :: Text,
    topologyParentId :: Text,
    topologyProvider :: ProviderKind,
    topologyKind :: ContextKind,
    topologyRoleName :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | A locally-checkable runtime fact. Single-argument witness kinds use
-- 'witnessName'; 'WitnessEnvEquals' also uses 'witnessValue'.
data WitnessKind
  = WitnessFileExists
  | WitnessUnixSocket
  | WitnessEnvEquals
  | WitnessExecutable
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data RuntimeWitness = RuntimeWitness
  { witnessKind :: WitnessKind,
    witnessName :: Text,
    witnessValue :: Text
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
    topologyFrames :: [TopologyFrame],
    currentFrame :: Text,
    runtimeWitnesses :: [RuntimeWitness],
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
  let frameId = generatedFrameId kind 0
   in
  BinaryContext
    { project = projectName,
      binary = binaryName,
      sourceRoot = root,
      contextKind = kind,
      roleName = defaultRoleName kind,
      parentChain = [],
      topologyFrames =
        [ TopologyFrame
            { topologyFrameId = frameId,
              topologyParentId = "",
              topologyProvider = providerForKind kind,
              topologyKind = kind,
              topologyRoleName = defaultRoleName kind
            }
        ],
      currentFrame = frameId,
      runtimeWitnesses = runtimeWitnessesForKind kind frameId,
      capabilities = capabilitiesForKind kind,
      allowedCommandClasses = commandClassesForKind kind,
      resourceEnvelope = envelope,
      childContextKinds = childKindsForKind kind
    }

-- | Grant a secondary role's authority to a context, so a single @<project>.dhall@
-- can declare **more than one role** (development_plan_standards § X) — e.g. a
-- project (deployment) authority that is also a @service@ authority. The primary
-- 'contextKind' and topology frame are unchanged; only the allowed command
-- classes and the local capabilities are unioned with the added role's, so each
-- command's gate ('commandAllowed') sees the capability it needs. Pure and
-- order-insensitive (idempotent when the role is already present).
addRole :: ContextKind -> BinaryContext -> BinaryContext
addRole role ctx =
  ctx
    { allowedCommandClasses = allowedCommandClasses ctx `union` commandClassesForKind role,
      capabilities = capabilities ctx `union` capabilitiesForKind role
    }

-- | Construct a host-orchestrator context.
hostOrchestratorContext :: Text -> Text -> Text -> ResourceEnvelope -> BinaryContext
hostOrchestratorContext projectName binaryName root envelope =
  contextForKind projectName binaryName root envelope HostOrchestrator

-- | Derive a VM-local orchestrator context from its parent.
deriveVMContext :: BinaryContext -> Text -> BinaryContext
deriveVMContext = deriveVMContextWithProvider IncusVMProvider

-- | Derive a VM-local orchestrator context for a specific VM provider.
deriveVMContextWithProvider :: ProviderKind -> BinaryContext -> Text -> BinaryContext
deriveVMContextWithProvider provider parent root =
  childContext
    parent
    root
    VMOrchestrator
    provider
    (capabilitiesForKind VMOrchestrator)
    (commandClassesForKind VMOrchestrator)
    (childKindsForKind VMOrchestrator)

-- | Derive a project-container context from its parent.
deriveContainerContext :: BinaryContext -> Text -> BinaryContext
deriveContainerContext parent root =
  childContext
    parent
    root
    VMProjectContainer
    DockerContainerProvider
    (capabilitiesForKind VMProjectContainer)
    (commandClassesForKind VMProjectContainer)
    (childKindsForKind VMProjectContainer)

-- | Derive the explicit Linux-GPU direct-host project-container context:
-- @host -> docker project container -> nvkind cluster@. This is intentionally a
-- separate constructor rather than a generic HostOrchestrator child, so ordinary
-- VM-backed runtime containers still require a VM ancestor.
deriveLinuxGpuContainerContext :: BinaryContext -> Text -> BinaryContext
deriveLinuxGpuContainerContext parent root =
  let frameId = generatedFrameId VMProjectContainer (length (topologyFrames parent))
      role = "linux-gpu-project-container"
      witnesses =
        [ RuntimeWitness WitnessUnixSocket "/var/run/docker.sock" "",
          RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_CURRENT_FRAME" frameId,
          directLinuxGpuWitness
        ]
   in childContextWith
        parent
        root
        VMProjectContainer
        DockerContainerProvider
        role
        witnesses
        (capabilitiesForKind VMProjectContainer)
        (commandClassesForKind VMProjectContainer)
        (childKindsForKind VMProjectContainer)

-- | Derive a cluster-service context from its parent.
deriveServiceContext :: BinaryContext -> Text -> BinaryContext
deriveServiceContext parent root =
  childContext
    parent
    root
    ClusterService
    KubernetesProvider
    (capabilitiesForKind ClusterService)
    (commandClassesForKind ClusterService)
    (childKindsForKind ClusterService)

-- | Derive a daemon context from its parent.
deriveDaemonContext :: BinaryContext -> Text -> BinaryContext
deriveDaemonContext parent root =
  case contextKind parent of
    HostOrchestrator -> deriveHostDaemonContext parent root
    _ -> deriveClusterDaemonContext parent root

-- | Derive a host-resident daemon context. Apple Silicon and Windows GPU
-- accelerator daemons run this leaf role on the host after the web ingress is
-- available.
deriveHostDaemonContext :: BinaryContext -> Text -> BinaryContext
deriveHostDaemonContext parent root =
  childDaemonContext parent root HostProvider

-- | Derive an in-cluster daemon-pod context. Linux CPU/GPU accelerator daemons
-- receive this config by ConfigMap, mirroring cluster-service config delivery.
deriveClusterDaemonContext :: BinaryContext -> Text -> BinaryContext
deriveClusterDaemonContext parent root =
  childDaemonContext parent root KubernetesProvider

-- | Derive a one-shot-job context from its parent.
deriveOneShotContext :: BinaryContext -> Text -> BinaryContext
deriveOneShotContext parent root =
  childContext
    parent
    root
    OneShotJob
    (providerForKind OneShotJob)
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
    (providerForKind TestHarness)
    (capabilitiesForKind TestHarness)
    (commandClassesForKind TestHarness)
    (childKindsForKind TestHarness)

-- | Create the standalone image-build context used by Dockerfile bootstrap
-- surfaces before a parent-derived runtime context exists.
imageBuildContainerContext :: Text -> Text -> Text -> ResourceEnvelope -> BinaryContext
imageBuildContainerContext projectName binaryName root envelope =
  contextForKind projectName binaryName root envelope ImageBuildContainer

-- | Backward-compatible name for the Dockerfile bootstrap context. Runtime
-- project containers must be parent-derived with 'deriveContainerContext'.
standaloneContainerContext :: Text -> Text -> Text -> ResourceEnvelope -> BinaryContext
standaloneContainerContext = imageBuildContainerContext

childContext ::
  BinaryContext ->
  Text ->
  ContextKind ->
  ProviderKind ->
  [Capability] ->
  [CommandClass] ->
  [ContextKind] ->
  BinaryContext
childContext parent root kind provider caps classes childKinds =
  childContextWith
    parent
    root
    kind
    provider
    (defaultRoleName kind)
    (runtimeWitnessesForKind kind frameId)
    caps
    classes
    childKinds
  where
    frameId = generatedFrameId kind (length (topologyFrames parent))

childContextWith ::
  BinaryContext ->
  Text ->
  ContextKind ->
  ProviderKind ->
  Text ->
  [RuntimeWitness] ->
  [Capability] ->
  [CommandClass] ->
  [ContextKind] ->
  BinaryContext
childContextWith parent root kind provider role witnesses caps classes childKinds =
  let frameId = generatedFrameId kind (length (topologyFrames parent))
      parentFrame = currentFrame parent
   in
  BinaryContext
    { project = project parent,
      binary = binary parent,
      sourceRoot = root,
      contextKind = kind,
      roleName = role,
      parentChain = parentChain parent ++ [ContextFrame (contextKind parent) (binary parent)],
      topologyFrames =
        topologyFrames parent
          ++ [ TopologyFrame
                { topologyFrameId = frameId,
                  topologyParentId = parentFrame,
                  topologyProvider = provider,
                  topologyKind = kind,
                  topologyRoleName = role
                }
             ],
      currentFrame = frameId,
      runtimeWitnesses = witnesses,
      capabilities = caps,
      allowedCommandClasses = classes,
      resourceEnvelope = resourceEnvelope parent,
      childContextKinds = childKinds
    }

childDaemonContext :: BinaryContext -> Text -> ProviderKind -> BinaryContext
childDaemonContext parent root provider =
  let frameId = generatedFrameId Daemon (length (topologyFrames parent))
      witnesses =
        case provider of
          KubernetesProvider ->
            [ RuntimeWitness WitnessFileExists "/var/run/secrets/kubernetes.io/serviceaccount/token" "",
              RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_CURRENT_FRAME" frameId
            ]
          _ ->
            [RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_CURRENT_FRAME" frameId]
   in childContextWith
        parent
        root
        Daemon
        provider
        (defaultRoleName Daemon)
        witnesses
        (capabilitiesForKind Daemon)
        (commandClassesForKind Daemon)
        (childKindsForKind Daemon)

capabilitiesForKind :: ContextKind -> [Capability]
capabilitiesForKind HostOrchestrator = [HostTools, IncusProvider]
capabilitiesForKind VMOrchestrator = [HostTools, DockerSocket, ContainerRuntime]
capabilitiesForKind VMProjectContainer = [DockerSocket, ContainerRuntime, KindNetwork]
capabilitiesForKind ImageBuildContainer = []
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
commandClassesForKind ImageBuildContainer =
  [ConfigInspectionCommand, ConfigGenerationCommand, CheckCodeCommand]
commandClassesForKind ClusterService =
  [ConfigInspectionCommand, ServiceCommand]
commandClassesForKind Daemon =
  [ConfigInspectionCommand, DaemonCommand, ServiceCommand]
commandClassesForKind OneShotJob =
  [ConfigInspectionCommand, ProjectCommand]
commandClassesForKind TestHarness =
  [ConfigInspectionCommand, ConfigGenerationCommand, ClusterLifecycleCommand, TestWorkflowCommand]

childKindsForKind :: ContextKind -> [ContextKind]
childKindsForKind HostOrchestrator =
  [ VMOrchestrator,
    ClusterService,
    Daemon,
    OneShotJob,
    TestHarness
  ]
childKindsForKind VMOrchestrator =
  [VMProjectContainer, ClusterService, Daemon, OneShotJob, TestHarness]
childKindsForKind VMProjectContainer =
  [ClusterService, Daemon, OneShotJob, TestHarness]
childKindsForKind ImageBuildContainer = []
childKindsForKind ClusterService = []
childKindsForKind Daemon = []
childKindsForKind OneShotJob = []
childKindsForKind TestHarness = [ClusterService]

-- | The default stable role label used in generated configs and logs.
defaultRoleName :: ContextKind -> Text
defaultRoleName HostOrchestrator = "host-orchestrator"
defaultRoleName VMOrchestrator = "vm-orchestrator"
defaultRoleName VMProjectContainer = "vm-project-container"
defaultRoleName ImageBuildContainer = "image-build-container"
defaultRoleName ClusterService = "cluster-service"
defaultRoleName Daemon = "daemon"
defaultRoleName OneShotJob = "one-shot-job"
defaultRoleName TestHarness = "test-harness"

generatedFrameId :: ContextKind -> Int -> Text
generatedFrameId kind n = defaultRoleName kind <> "-" <> T.pack (show n)

providerForKind :: ContextKind -> ProviderKind
providerForKind HostOrchestrator = HostProvider
providerForKind VMOrchestrator = IncusVMProvider
providerForKind VMProjectContainer = DockerContainerProvider
providerForKind ImageBuildContainer = DockerContainerProvider
providerForKind ClusterService = KubernetesProvider
providerForKind Daemon = HostProvider
providerForKind OneShotJob = DockerContainerProvider
providerForKind TestHarness = DockerContainerProvider

runtimeWitnessesForKind :: ContextKind -> Text -> [RuntimeWitness]
runtimeWitnessesForKind VMOrchestrator _ =
  [RuntimeWitness WitnessFileExists "/run/hostbootstrap/vm-provider" ""]
runtimeWitnessesForKind VMProjectContainer frameId =
  [ RuntimeWitness WitnessUnixSocket "/var/run/docker.sock" "",
    RuntimeWitness WitnessFileExists "/run/hostbootstrap/vm-provider" "",
    RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_CURRENT_FRAME" frameId
  ]
runtimeWitnessesForKind ClusterService _ =
  [RuntimeWitness WitnessFileExists "/var/run/secrets/kubernetes.io/serviceaccount/token" ""]
runtimeWitnessesForKind Daemon frameId =
  [RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_CURRENT_FRAME" frameId]
runtimeWitnessesForKind _ _ = []

directLinuxGpuWitness :: RuntimeWitness
directLinuxGpuWitness =
  RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_DIRECT_CONTAINER" "linux-gpu"

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
  | ContextCurrentFrameMissing Text
  | ContextCurrentFrameKindMismatch Text ContextKind ContextKind
  | ContextTopologyParentMissing Text Text
  | ContextRequiredAncestorMissing ContextKind ContextKind
  | ContextCommandNotAllowed CommandClass ContextKind
  | ContextCapabilityMissing Capability
  | ContextRuntimeWitnessFailed RuntimeWitness String
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
    Hoist.unionOf @ProviderKind "ProviderKind",
    Hoist.unionOf @WitnessKind "WitnessKind",
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
  | Nothing <- currentTopologyFrame ctx =
      Left (ContextCurrentFrameMissing (currentFrame ctx))
  | Just frame <- currentTopologyFrame ctx,
    topologyKind frame /= contextKind ctx =
      Left (ContextCurrentFrameKindMismatch (currentFrame ctx) (contextKind ctx) (topologyKind frame))
  | Left err <- ancestorKinds ctx =
      Left err
  | not (commandAllowed ctx (requiredCommandClass req)) =
      Left (ContextCommandNotAllowed (requiredCommandClass req) (contextKind ctx))
  | Just missing <- find (`notElem` capabilities ctx) (requiredCapabilities req) =
      Left (ContextCapabilityMissing missing)
  | Right ancestors <- ancestorKinds ctx,
    Just err <- requiredAncestorError ctx ancestors =
      Left err
  | otherwise = Right ctx

currentTopologyFrame :: BinaryContext -> Maybe TopologyFrame
currentTopologyFrame ctx =
  find ((== currentFrame ctx) . topologyFrameId) (topologyFrames ctx)

ancestorKinds :: BinaryContext -> Either BinaryContextError [ContextKind]
ancestorKinds ctx =
  case currentTopologyFrame ctx of
    Nothing -> Left (ContextCurrentFrameMissing (currentFrame ctx))
    Just frame -> go [] frame
  where
    go acc frame
      | T.null (topologyParentId frame) = Right acc
      | otherwise =
          case find ((== topologyParentId frame) . topologyFrameId) (topologyFrames ctx) of
            Nothing -> Left (ContextTopologyParentMissing (topologyFrameId frame) (topologyParentId frame))
            Just parent -> go (topologyKind parent : acc) parent

requiredAncestorError :: BinaryContext -> [ContextKind] -> Maybe BinaryContextError
requiredAncestorError ctx ancestors =
  case contextKind ctx of
    VMProjectContainer
      | VMOrchestrator `elem` ancestors -> Nothing
      | isExplicitLinuxGpuContainer ctx -> Nothing
      | otherwise -> Just (ContextRequiredAncestorMissing VMProjectContainer VMOrchestrator)
    _ -> Nothing

isExplicitLinuxGpuContainer :: BinaryContext -> Bool
isExplicitLinuxGpuContainer ctx =
  directLinuxGpuWitness `elem` runtimeWitnesses ctx
    && case currentTopologyFrame ctx of
      Just frame
        | topologyKind frame == VMProjectContainer,
          topologyProvider frame == DockerContainerProvider ->
            case find ((== topologyParentId frame) . topologyFrameId) (topologyFrames ctx) of
              Just parent -> topologyKind parent == HostOrchestrator
              Nothing -> False
      _ -> False

-- | Validate both the pure context structure and the locally checkable runtime
-- witnesses in the decoded context.
validateRuntimeContext :: ContextRequirement -> BinaryContext -> IO (Either BinaryContextError BinaryContext)
validateRuntimeContext req ctx =
  case validateContext req ctx of
    Left err -> pure (Left err)
    Right ok -> do
      witnessResults <- traverse checkRuntimeWitness (runtimeWitnesses ok)
      pure $ case findLeft witnessResults of
        Just err -> Left err
        Nothing -> Right ok

findLeft :: [Either a b] -> Maybe a
findLeft [] = Nothing
findLeft (Left x : _) = Just x
findLeft (Right _ : xs) = findLeft xs

checkRuntimeWitness :: RuntimeWitness -> IO (Either BinaryContextError ())
checkRuntimeWitness witness =
  case witnessKind witness of
    WitnessFileExists -> do
      exists <- doesFileExist name
      pure $
        if exists
          then Right ()
          else failed ("missing file " ++ name)
    WitnessUnixSocket -> do
#ifdef mingw32_HOST_OS
      pure $ failed ("unix socket witnesses are not supported on Windows: " ++ name)
#else
      result <- try (getFileStatus name) :: IO (Either SomeException FileStatus)
      pure $ case result of
        Right status
          | isSocket status -> Right ()
        Right _ -> failed ("not a unix socket " ++ name)
        Left err -> failed ("missing unix socket " ++ name ++ ": " ++ firstLine (show err))
#endif
    WitnessEnvEquals -> do
      actual <- lookupEnv name
      pure $ case actual of
        Just value
          | value == T.unpack (witnessValue witness) -> Right ()
        Just value -> failed ("environment " ++ name ++ " was " ++ show value)
        Nothing -> failed ("environment " ++ name ++ " is unset")
    WitnessExecutable -> do
      found <- findExecutable name
      pure $ case found of
        Just _ -> Right ()
        Nothing -> failed ("executable not found on PATH: " ++ name)
  where
    name = T.unpack (witnessName witness)
    failed detail = Left (ContextRuntimeWitnessFailed witness detail)
#ifndef mingw32_HOST_OS
    firstLine = takeWhile (/= '\n')
#endif

-- | Load and validate a context file.
readAndValidateContextFile :: FilePath -> ContextRequirement -> IO (Either BinaryContextError BinaryContext)
readAndValidateContextFile path req = do
  loaded <- readContextFile path
  case loaded of
    Left err -> pure (Left err)
    Right ctx -> validateRuntimeContext req ctx

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
    ContextCurrentFrameMissing frame ->
      "binary context: current frame " ++ txt frame ++ " is not present in topologyFrames"
    ContextCurrentFrameKindMismatch frame expected actual ->
      "binary context: current frame "
        ++ txt frame
        ++ " has kind "
        ++ show actual
        ++ " but contextKind is "
        ++ show expected
    ContextTopologyParentMissing child parent ->
      "binary context: topology frame " ++ txt child ++ " references missing parent " ++ txt parent
    ContextRequiredAncestorMissing kind required ->
      "binary context: " ++ show kind ++ " requires ancestor " ++ show required
    ContextCommandNotAllowed cls kind ->
      "binary context: command " ++ show cls ++ " is not allowed in " ++ show kind
    ContextCapabilityMissing cap ->
      "binary context: missing capability " ++ show cap
    ContextRuntimeWitnessFailed witness detail ->
      "binary context: runtime witness " ++ show (witnessKind witness) ++ " failed for " ++ txt (witnessName witness) ++ ": " ++ detail
  where
    txt = T.unpack
    firstLine = takeWhile (/= '\n')
