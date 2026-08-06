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
    ContextPlacement (..),
    ContextRequirement (..),
    ProviderKind (..),
    ResourceEnvelope (..),
    RuntimeWitness (..),
    TopologyFrame (..),
    WitnessKind (..),
    BinaryContextError (..),
    defaultRoleName,
    contextForKind,
    addRole,
    roleAdditionAllowed,
    validateTopology,
    placementFor,
    contextPlacement,
    placementAllowsCommand,
    isOrchestrationPlacement,
    isRootFrame,
    requiredWitnesses,
    contextRequiredWitnesses,
    hostOrchestratorContext,
    deriveVMContextWithProvider,
    deriveVMContext,
    deriveContainerContext,
    deriveLinuxGpuContainerContext,
    isExplicitLinuxGpuContainer,
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
import Data.Foldable (traverse_)
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
    childContextKinds :: [ContextKind]
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Construct a standalone context of the requested kind. Parent-generated
-- child contexts use the same role-specific authority, plus a parent frame.
contextForKind :: Text -> Text -> Text -> ContextKind -> BinaryContext
contextForKind projectName binaryName root kind =
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
      runtimeWitnesses = witnessesForFrame kind (providerForKind kind) Nothing frameId,
      capabilities = capabilitiesForKind kind,
      allowedCommandClasses = commandClassesForKind kind,
      childContextKinds = childKindsForKind kind
    }

{- | Grant a secondary role's authority to a context, so a single
@<project>.dhall@ can declare **more than one runtime role**
(development_plan_standards § X) — e.g. a cluster service that is also the
project's daemon.

This is a validating smart constructor, not a union. @alsoRoles@ reaches it from
operator input, so an unchecked union would let a caller self-assert authority
its placement cannot hold: a @Daemon@ primary could acquire
@HostOrchestratorCommand@ and @ProjectCommand@ merely by naming
@host-orchestrator@ as an extra role. 'roleAdditionAllowed' is the closed
relation that forbids exactly that (§ 15.9).

The primary 'contextKind' and topology frame are unchanged; only the allowed
command classes and local capabilities are unioned, and only for a permitted
pair. Pure and order-insensitive, and idempotent when the role is already the
primary.
-}
addRole :: ContextKind -> BinaryContext -> Either BinaryContextError BinaryContext
addRole role ctx
  | role == contextKind ctx = Right ctx
  | not (roleAdditionAllowed (contextKind ctx) role) =
      Left (ContextRoleAdditionRefused (contextKind ctx) role)
  | otherwise =
      Right
        ctx
          { allowedCommandClasses = allowedCommandClasses ctx `union` commandClassesForKind role,
            capabilities = capabilities ctx `union` capabilitiesForKind role
          }

{- | The closed relation of permitted (primary, additional) role pairs.

Two rules, both from § 15.9's deliverable:

* a **non-leaf** primary — one that can own child frames — cannot acquire
  service-run authority, because a frame that orchestrates children is not the
  leaf a service role is served from;
* a role may not contribute a command class the primary's own placement does not
  already justify. That is what stops @Daemon@ and @ImageBuildContainer@
  primaries from becoming project/lifecycle authorities by unioning
  @ClusterLifecycleCommand@ or @HostOrchestratorCommand@.

The surviving legal case is therefore leaf-to-leaf: a service placement may also
serve another service role in the same frame.
-}
roleAdditionAllowed :: ContextKind -> ContextKind -> Bool
roleAdditionAllowed primary role =
  isLeafPlacement primary
    && isServiceRole role
    && isServiceRole primary

-- | A placement that owns no child frames.
isLeafPlacement :: ContextKind -> Bool
isLeafPlacement = null . childKindsForKind

-- | A role whose authority is served from a leaf frame.
isServiceRole :: ContextKind -> Bool
isServiceRole ClusterService = True
isServiceRole Daemon = True
isServiceRole _ = False

-- | Construct a host-orchestrator context.
hostOrchestratorContext :: Text -> Text -> Text -> BinaryContext
hostOrchestratorContext projectName binaryName root =
  contextForKind projectName binaryName root HostOrchestrator

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
  childContextWith
    parent
    root
    VMProjectContainer
    DockerContainerProvider
    "linux-gpu-project-container"
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
imageBuildContainerContext :: Text -> Text -> Text -> BinaryContext
imageBuildContainerContext projectName binaryName root =
  contextForKind projectName binaryName root ImageBuildContainer

-- | Backward-compatible name for the Dockerfile bootstrap context. Runtime
-- project containers must be parent-derived with 'deriveContainerContext'.
standaloneContainerContext :: Text -> Text -> Text -> BinaryContext
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
  childContextWith parent root kind provider (defaultRoleName kind) caps classes childKinds

-- | Derive a child context, projecting the required-witness set for the child's
-- own placement (§ 15.9) rather than accepting a caller-supplied witness list.
childContextWith ::
  BinaryContext ->
  Text ->
  ContextKind ->
  ProviderKind ->
  Text ->
  [Capability] ->
  [CommandClass] ->
  [ContextKind] ->
  BinaryContext
childContextWith parent root kind provider role caps classes childKinds =
  let frameId = generatedFrameId kind (length (topologyFrames parent))
      parentFrame = currentFrame parent
      witnesses = witnessesForFrame kind provider (Just (contextKind parent)) frameId
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
      childContextKinds = childKinds
    }

childDaemonContext :: BinaryContext -> Text -> ProviderKind -> BinaryContext
childDaemonContext parent root provider =
  childContextWith
    parent
    root
    Daemon
    provider
    (defaultRoleName Daemon)
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

{- | The closed placement discriminator the required-witness relation is indexed
by (§ 15.9).

A placement is not a 'ContextKind'. It is the exact (primary kind, owning
provider, structural position) triple that determines which local runtime facts
must hold, so two frames that share a kind but sit in different substrates —
a Kubernetes daemon pod versus a host-resident daemon, a VM-backed project
container versus the direct Linux GPU one — are separate placements with
separate required sets.

It is derived from the *validated topology graph*, never from the declared
witness list, so a config cannot select a weaker placement by editing the facts
it claims.
-}
data ContextPlacement
  = HostOrchestratorPlacement
  | -- | indexed by the VM provider that owns the frame
    VMOrchestratorPlacement ProviderKind
  | VMBackedProjectContainerPlacement
  | -- | @host -> docker project container -> nvkind@, with no VM between
    DirectLinuxGpuContainerPlacement
  | ImageBuildContainerPlacement
  | ClusterServicePlacement
  | ClusterDaemonPlacement
  | HostDaemonPlacement
  | OneShotJobPlacement
  | TestHarnessPlacement
  deriving (Eq, Show)

{- | The closed (kind, provider, parent kind) → placement relation.

'Nothing' means the pair is not a legal placement at all — for example a
@ClusterService@ frame claiming @HostProvider@ — and 'validateTopology' refuses
such a frame with 'ContextTopologyIllegalProvider' rather than guessing a
required set for it.

The parent kind discriminates only where it must: a Docker project container
whose parent is the host orchestrator is the explicit direct Linux GPU lane,
while one under a VM orchestrator is the ordinary VM-backed container. A
standalone container with no parent is treated as VM-backed and then refused by
'requiredAncestorError'.
-}
placementFor :: ContextKind -> ProviderKind -> Maybe ContextKind -> Maybe ContextPlacement
placementFor kind provider parentKind = case (kind, provider) of
  (HostOrchestrator, HostProvider) -> Just HostOrchestratorPlacement
  (VMOrchestrator, IncusVMProvider) -> Just (VMOrchestratorPlacement IncusVMProvider)
  (VMOrchestrator, LimaVMProvider) -> Just (VMOrchestratorPlacement LimaVMProvider)
  (VMOrchestrator, Wsl2VMProvider) -> Just (VMOrchestratorPlacement Wsl2VMProvider)
  (VMProjectContainer, DockerContainerProvider)
    | parentKind == Just HostOrchestrator -> Just DirectLinuxGpuContainerPlacement
    | otherwise -> Just VMBackedProjectContainerPlacement
  (ImageBuildContainer, DockerContainerProvider) -> Just ImageBuildContainerPlacement
  (ClusterService, KubernetesProvider) -> Just ClusterServicePlacement
  (Daemon, KubernetesProvider) -> Just ClusterDaemonPlacement
  (Daemon, HostProvider) -> Just HostDaemonPlacement
  (OneShotJob, DockerContainerProvider) -> Just OneShotJobPlacement
  (TestHarness, DockerContainerProvider) -> Just TestHarnessPlacement
  _ -> Nothing

{- | The exact set of locally checkable runtime facts a placement requires.

This is the single definition of the relation: the child-context constructors
project it into the generated config, and 'validateContext' re-derives it from
the topology and requires the declared list to equal it exactly. There is no
second hand-written witness table.
-}
requiredWitnesses :: ContextPlacement -> Text -> [RuntimeWitness]
requiredWitnesses HostOrchestratorPlacement _ = []
requiredWitnesses (VMOrchestratorPlacement _) _ = [vmProviderWitness]
requiredWitnesses VMBackedProjectContainerPlacement frameId =
  [dockerSocketWitness, vmProviderWitness, currentFrameWitness frameId]
requiredWitnesses DirectLinuxGpuContainerPlacement frameId =
  [dockerSocketWitness, currentFrameWitness frameId, directLinuxGpuWitness]
requiredWitnesses ImageBuildContainerPlacement _ = []
requiredWitnesses ClusterServicePlacement _ = [serviceAccountWitness]
requiredWitnesses ClusterDaemonPlacement frameId =
  [serviceAccountWitness, currentFrameWitness frameId]
requiredWitnesses HostDaemonPlacement frameId = [currentFrameWitness frameId]
requiredWitnesses OneShotJobPlacement _ = []
requiredWitnesses TestHarnessPlacement _ = []

{- | Whether the current frame is the chain's own **root** — derived from the
validated topology graph rather than read off @parentChain@.

'validateTopology' has already proved that the declared @parentChain@ equals the
ancestry the edges describe, so the two agree by the time a command is
authorized. Deriving it here keeps the authority on the graph, which is what
makes the root half of 'placementAllowsCommand' a structural fact rather than a
field a config fills in.
-}
isRootFrame :: BinaryContext -> Bool
isRootFrame ctx =
  maybe False (T.null . topologyParentId) (currentTopologyFrame ctx)

{- | A placement that interprets a segment of the lift chain and can therefore
own child frames. The complement — a cluster service, either daemon placement, a
one-shot job, an image-build container — is a **leaf**: it hosts no chain, so no
lifecycle verb belongs to it.
-}
isOrchestrationPlacement :: ContextPlacement -> Bool
isOrchestrationPlacement placement = case placement of
  HostOrchestratorPlacement -> True
  VMOrchestratorPlacement _ -> True
  VMBackedProjectContainerPlacement -> True
  DirectLinuxGpuContainerPlacement -> True
  TestHarnessPlacement -> True
  ImageBuildContainerPlacement -> False
  ClusterServicePlacement -> False
  ClusterDaemonPlacement -> False
  HostDaemonPlacement -> False
  OneShotJobPlacement -> False

{- | The closed (placement, root-ness, command class) relation the lifecycle
verbs dispatch through (§ X).

'commandAllowed' consults @allowedCommandClasses@, which is a **declared** list:
it is generated by 'contextForKind' / 'childContextWith' and narrowed by
'addRole', but a hand-edited or forged @<project>.dhall@ owns those bytes, so on
its own it is a claim rather than a fact. That is exactly the shape the exact
required-witness set replaced for 'runtimeWitnesses' — and the same repair
applies here, for the two verbs whose meaning is structural:

* @project up@ interprets the chain from a frame, so it runs only from a frame
  that *is* a chain segment ('isOrchestrationPlacement'). A daemon or
  cluster-service leaf that lists @ClusterLifecycleCommand@ is refused by its
  placement, not believed;
* @project down@ / @project destroy@ unwind the chain from its root, so they
  additionally require the **empty-parent** half — the current frame is the
  topology's root — and the root of an orchestration chain is the host
  orchestrator. This is the exact root-kind/empty-parent check the lifecycle
  verbs previously lacked.

Every other class is placement-independent: @check-code@ and config inspection
are legal wherever the context otherwise validates, and @service run@ keeps its
own leaf gate at the command layer.
-}
placementAllowsCommand :: ContextPlacement -> Bool -> CommandClass -> Bool
placementAllowsCommand placement atRoot cls = case cls of
  ClusterLifecycleCommand -> isOrchestrationPlacement placement
  HostOrchestratorCommand -> atRoot && placement == HostOrchestratorPlacement
  EnsureCommand -> True
  ConfigInspectionCommand -> True
  ConfigGenerationCommand -> True
  ContextCreationCommand -> True
  TestWorkflowCommand -> True
  CheckCodeCommand -> True
  DaemonCommand -> True
  ServiceCommand -> True
  ProjectCommand -> True

-- | The required set for a frame described by its kind, provider, parent kind
-- and identifier. An illegal pair contributes no witnesses; 'validateTopology'
-- refuses the frame itself.
witnessesForFrame :: ContextKind -> ProviderKind -> Maybe ContextKind -> Text -> [RuntimeWitness]
witnessesForFrame kind provider parentKind frameId =
  maybe [] (`requiredWitnesses` frameId) (placementFor kind provider parentKind)

vmProviderWitness :: RuntimeWitness
vmProviderWitness = RuntimeWitness WitnessFileExists "/run/hostbootstrap/vm-provider" ""

dockerSocketWitness :: RuntimeWitness
dockerSocketWitness = RuntimeWitness WitnessUnixSocket "/var/run/docker.sock" ""

serviceAccountWitness :: RuntimeWitness
serviceAccountWitness =
  RuntimeWitness WitnessFileExists "/var/run/secrets/kubernetes.io/serviceaccount/token" ""

currentFrameWitness :: Text -> RuntimeWitness
currentFrameWitness = RuntimeWitness WitnessEnvEquals "HOSTBOOTSTRAP_CURRENT_FRAME"

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
  | -- | two topology frames declare the same identifier
    ContextTopologyDuplicateFrame Text
  | -- | a frame identifier is empty
    ContextTopologyEmptyFrameId
  | -- | the topology has no root frame, or more than one
    ContextTopologyRootCount Int
  | -- | following parents from this frame revisits it
    ContextTopologyCycle Text
  | -- | a frame is not reachable from the root
    ContextTopologyUnreachable Text
  | -- | a child frame's kind is not a legal child of its parent's kind
    ContextTopologyIllegalChild Text ContextKind ContextKind
  | -- | the declared @parentChain@ disagrees with the edge-derived ancestry
    ContextParentChainMismatch [ContextKind] [ContextKind]
  | -- | this primary kind may not union that role's authority
    ContextRoleAdditionRefused ContextKind ContextKind
  | -- | a frame's kind cannot be owned by the provider it declares
    ContextTopologyIllegalProvider Text ContextKind ProviderKind
  | -- | the declared witness list is not the exact set this placement requires:
    -- @missing@ then @unexpected@
    ContextWitnessSetMismatch [RuntimeWitness] [RuntimeWitness]
  | -- | two declared witnesses share a kind and name, so the list is duplicated
    -- or self-contradictory
    ContextWitnessDuplicate RuntimeWitness
  | -- | the command class is declared, but this placement does not host it:
    -- the class, the derived placement, and whether the frame is the chain root
    ContextPlacementRefusesCommand CommandClass ContextPlacement Bool
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
  | Left err <- validateTopology ctx =
      Left err
  | Left err <- ancestorKinds ctx =
      Left err
  | Left err <- checkWitnessSet ctx =
      Left err
  | not (commandAllowed ctx (requiredCommandClass req)) =
      Left (ContextCommandNotAllowed (requiredCommandClass req) (contextKind ctx))
  -- The declared class list said yes. Ask the validated topology as well, so a
  -- forged list cannot place a leaf frame in an orchestration verb.
  | Right placement <- contextPlacement ctx,
    not (placementAllowsCommand placement (isRootFrame ctx) (requiredCommandClass req)) =
      Left
        ( ContextPlacementRefusesCommand
            (requiredCommandClass req)
            placement
            (isRootFrame ctx)
        )
  | Just missing <- find (`notElem` capabilities ctx) (requiredCapabilities req) =
      Left (ContextCapabilityMissing missing)
  | Right ancestors <- ancestorKinds ctx,
    Just err <- requiredAncestorError ctx ancestors =
      Left err
  | otherwise = Right ctx

{- | The one total graph validator every decoded topology passes before any
command is authorized (§ 15.9).

A decoded @<project>.dhall@ is untrusted input, so the frame list is checked as
a graph rather than trusted as one: identifiers are non-empty and unique, every
non-root frame resolves to exactly one declared parent, there is exactly one
root, no parent walk revisits a frame, every frame is reachable from the root,
each child's kind is a legal child of its parent's kind, and the declared
@parentChain@ agrees with the ancestry the edges actually describe.

The cycle check is load-bearing rather than defensive: the ancestor walk follows
@topologyParentId@ with no memory of where it has been, so a topology whose
frames name each other as parents would loop forever. A hand-edited or
maliciously supplied config could reach it. Here every traversal carries a
visited set and terminates.
-}
validateTopology :: BinaryContext -> Either BinaryContextError ()
validateTopology ctx = do
  traverse_ requireFrameId frames
  traverse_ requireUniqueId ids
  root <- requireSingleRoot
  traverse_ requireResolvableParent frames
  traverse_ (requireAcyclic []) frames
  reachable <- Right (descendantsOf root)
  traverse_ (requireReachable reachable) ids
  traverse_ requireLegalChild frames
  traverse_ requireLegalProvider frames
  requireParentChainAgrees
  where
    frames = topologyFrames ctx
    ids = map topologyFrameId frames

    requireFrameId frame
      | T.null (topologyFrameId frame) = Left ContextTopologyEmptyFrameId
      | otherwise = Right ()

    requireUniqueId frameId
      | length (filter (== frameId) ids) > 1 =
          Left (ContextTopologyDuplicateFrame frameId)
      | otherwise = Right ()

    roots = [frame | frame <- frames, T.null (topologyParentId frame)]

    requireSingleRoot = case roots of
      [root] -> Right root
      other -> Left (ContextTopologyRootCount (length other))

    frameById frameId = find ((== frameId) . topologyFrameId) frames

    requireResolvableParent frame
      | T.null (topologyParentId frame) = Right ()
      | Just _ <- frameById (topologyParentId frame) = Right ()
      | otherwise =
          Left
            ( ContextTopologyParentMissing
                (topologyFrameId frame)
                (topologyParentId frame)
            )

    -- Walk to the root carrying every frame already seen, so a cycle is a
    -- structured refusal instead of a hang.
    requireAcyclic seen frame
      | topologyFrameId frame `elem` seen =
          Left (ContextTopologyCycle (topologyFrameId frame))
      | T.null (topologyParentId frame) = Right ()
      | otherwise =
          case frameById (topologyParentId frame) of
            Nothing -> Right ()
            Just parent -> requireAcyclic (topologyFrameId frame : seen) parent

    descendantsOf root = go [] [topologyFrameId root]
      where
        go acc [] = acc
        go acc (frameId : rest)
          | frameId `elem` acc = go acc rest
          | otherwise =
              let children =
                    [ topologyFrameId child
                    | child <- frames
                    , topologyParentId child == frameId
                    ]
               in go (frameId : acc) (children ++ rest)

    requireReachable reachable frameId
      | frameId `elem` reachable = Right ()
      | otherwise = Left (ContextTopologyUnreachable frameId)

    requireLegalChild frame
      | T.null (topologyParentId frame) = Right ()
      | otherwise =
          case frameById (topologyParentId frame) of
            Nothing -> Right ()
            Just parent
              | topologyKind frame `elem` childKindsForKind (topologyKind parent) ->
                  Right ()
              -- The direct Linux GPU lane really does hang a project container
              -- off the host orchestrator with no VM between them. That edge is
              -- structurally permitted here and policed by
              -- 'requiredAncestorError', which refuses it unless the explicit
              -- direct-container witness is present — so the refusal keeps its
              -- specific diagnostic instead of being masked by a generic
              -- illegal-child error.
              | topologyKind parent == HostOrchestrator
              , topologyKind frame == VMProjectContainer ->
                  Right ()
              | otherwise ->
                  Left
                    ( ContextTopologyIllegalChild
                        (topologyFrameId frame)
                        (topologyKind parent)
                        (topologyKind frame)
                    )

    -- A frame's provider is part of its placement (§ 15.9), so a kind the
    -- provider cannot own — a cluster service claiming @HostProvider@, say — is
    -- refused here rather than silently receiving some other placement's
    -- required-witness set.
    requireLegalProvider frame
      | Just _ <- placementFor (topologyKind frame) (topologyProvider frame) parentKind =
          Right ()
      | otherwise =
          Left
            ( ContextTopologyIllegalProvider
                (topologyFrameId frame)
                (topologyKind frame)
                (topologyProvider frame)
            )
      where
        parentKind = topologyKind <$> frameById (topologyParentId frame)

    requireParentChainAgrees =
      case ancestorKinds ctx of
        Left err -> Left err
        Right derived
          | declared == derived -> Right ()
          | otherwise -> Left (ContextParentChainMismatch declared derived)
      where
        declared = map frameKind (parentChain ctx)

currentTopologyFrame :: BinaryContext -> Maybe TopologyFrame
currentTopologyFrame ctx =
  find ((== currentFrame ctx) . topologyFrameId) (topologyFrames ctx)

parentFrameOf :: BinaryContext -> TopologyFrame -> Maybe TopologyFrame
parentFrameOf ctx frame =
  find ((== topologyParentId frame) . topologyFrameId) (topologyFrames ctx)

-- | The placement the current frame occupies, derived from the topology graph
-- alone. A frame whose kind and provider are not a legal pair has no placement.
contextPlacement :: BinaryContext -> Either BinaryContextError ContextPlacement
contextPlacement ctx = do
  frame <-
    maybe (Left (ContextCurrentFrameMissing (currentFrame ctx))) Right (currentTopologyFrame ctx)
  let parentKind = topologyKind <$> parentFrameOf ctx frame
  maybe
    ( Left
        ( ContextTopologyIllegalProvider
            (topologyFrameId frame)
            (topologyKind frame)
            (topologyProvider frame)
        )
    )
    Right
    (placementFor (topologyKind frame) (topologyProvider frame) parentKind)

-- | The exact runtime-witness set the current frame's placement requires.
contextRequiredWitnesses :: BinaryContext -> Either BinaryContextError [RuntimeWitness]
contextRequiredWitnesses ctx =
  (\placement -> requiredWitnesses placement (currentFrame ctx)) <$> contextPlacement ctx

{- | Require the declared witness list to be exactly the set this placement
demands (§ 15.9).

Before this check the declared list was the only authority: validation verified
whatever a decoded @<project>.dhall@ happened to claim, so an **empty** or
trimmed list verified nothing and still authorized the command. The required set
is now re-derived from the validated topology and compared exactly, so a
missing, extra, irrelevant, duplicated, or self-contradictory entry refuses the
context instead of weakening it.

Duplicates are keyed on (kind, name) rather than the whole witness, which is
what makes a *contradictory* pair — the same environment variable required to
equal two different values — a refusal rather than a list one of whose members
happens to hold.
-}
checkWitnessSet :: BinaryContext -> Either BinaryContextError ()
checkWitnessSet ctx = do
  required <- contextRequiredWitnesses ctx
  let declared = runtimeWitnesses ctx
      key w = (witnessKind w, witnessName w)
      duplicated = filter (\w -> length (filter ((== key w) . key) declared) > 1) declared
      missing = filter (`notElem` declared) required
      unexpected = filter (`notElem` required) declared
  case duplicated of
    (w : _) -> Left (ContextWitnessDuplicate w)
    [] ->
      if null missing && null unexpected
        then Right ()
        else Left (ContextWitnessSetMismatch missing unexpected)

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

{- | Whether the current frame is the explicit direct Linux GPU project
container — the one lane that legitimately hangs a container off the host
orchestrator with no VM between them.

This is a **structural** question about the validated topology, not a claim the
config makes. It previously required @directLinuxGpuWitness@ to appear in the
declared 'runtimeWitnesses', which meant a hand-edited config could opt out of
the VM-ancestor requirement simply by listing that witness. The placement is now
derived from the graph, and the witness is instead *required* by that placement
('requiredWitnesses') and verified against the real environment by
'validateRuntimeContext'.
-}
isExplicitLinuxGpuContainer :: BinaryContext -> Bool
isExplicitLinuxGpuContainer ctx =
  contextPlacement ctx == Right DirectLinuxGpuContainerPlacement

{- | Validate the pure context structure, then verify every member of the
required-witness set against the real local environment.

The set checked here is the one 'contextRequiredWitnesses' derives from the
placement, not the list the config declares. 'validateContext' has already
proved the two are equal, so this is the same set — but deriving it keeps the
authority on the closed relation rather than on untrusted input.
-}
validateRuntimeContext :: ContextRequirement -> BinaryContext -> IO (Either BinaryContextError BinaryContext)
validateRuntimeContext req ctx =
  case validateContext req ctx >>= \ok -> (,) ok <$> contextRequiredWitnesses ok of
    Left err -> pure (Left err)
    Right (ok, required) -> do
      witnessResults <- traverse checkRuntimeWitness required
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
    ContextTopologyDuplicateFrame frame ->
      "binary context: topology declares frame " ++ txt frame ++ " more than once"
    ContextTopologyEmptyFrameId ->
      "binary context: a topology frame has an empty identifier"
    ContextTopologyRootCount count ->
      "binary context: topology must have exactly one root frame, found "
        ++ show count
    ContextTopologyCycle frame ->
      "binary context: topology parent chain revisits frame " ++ txt frame
    ContextTopologyUnreachable frame ->
      "binary context: topology frame " ++ txt frame ++ " is not reachable from the root"
    ContextTopologyIllegalChild frame parent child ->
      "binary context: topology frame "
        ++ txt frame
        ++ " declares kind "
        ++ show child
        ++ ", which is not a legal child of "
        ++ show parent
    ContextParentChainMismatch declared derived ->
      "binary context: declared parentChain "
        ++ show declared
        ++ " disagrees with the topology edges "
        ++ show derived
    ContextRoleAdditionRefused primary role ->
      "binary context: a "
        ++ show primary
        ++ " placement may not acquire "
        ++ show role
        ++ " authority"
    ContextCommandNotAllowed cls kind ->
      "binary context: command " ++ show cls ++ " is not allowed in " ++ show kind
    ContextCapabilityMissing cap ->
      "binary context: missing capability " ++ show cap
    ContextRuntimeWitnessFailed witness detail ->
      "binary context: runtime witness " ++ show (witnessKind witness) ++ " failed for " ++ txt (witnessName witness) ++ ": " ++ detail
    ContextTopologyIllegalProvider frame kind provider ->
      "binary context: topology frame "
        ++ txt frame
        ++ " declares kind "
        ++ show kind
        ++ ", which cannot be owned by "
        ++ show provider
    ContextWitnessSetMismatch missing unexpected ->
      "binary context: declared runtimeWitnesses are not this placement's required set"
        ++ describe "missing" missing
        ++ describe "unexpected" unexpected
    ContextWitnessDuplicate witness ->
      "binary context: runtimeWitnesses declare "
        ++ show (witnessKind witness)
        ++ " "
        ++ txt (witnessName witness)
        ++ " more than once"
    ContextPlacementRefusesCommand cls placement atRoot ->
      "binary context: command "
        ++ show cls
        ++ " is declared but "
        ++ show placement
        ++ (if atRoot then " (the chain root)" else " (not the chain root)")
        ++ " does not host it"
  where
    describe _ [] = ""
    describe label ws = "; " ++ label ++ " " ++ show (map witnessName ws)
    txt = T.unpack
    firstLine = takeWhile (/= '\n')
