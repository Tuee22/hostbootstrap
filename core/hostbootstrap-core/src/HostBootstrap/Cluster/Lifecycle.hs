{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Plan-owned cluster packages, profile paths, and pure lifecycle decisions.

Production and Harness profiles retain their exact durable roots and declared
node topology. The pure teardown partition preserves durable data. Actual
creation, readiness, cordoning and conditional release belong to the owned
cluster backend; this module supplies their plan and rendering vocabulary.
-}
module HostBootstrap.Cluster.Lifecycle (
    ClusterProfile (Production),
    mkTestCaseProfile,
    clusterProfileRunKey,
    ClusterDriver (..),
    ClusterPlan (..),
    RetainedClusterProjection,
    retainedClusterProjection,
    retainedClusterName,
    retainedClusterNodeNames,
    retainedClusterStateDirectory,
    retainedClusterKubeconfigPath,
    ClusterPackageError (..),
    PlanOwnedCluster,
    withPlanOwnedCluster,
    withExecutionOwnedCluster,
    PlanOwnedClusterConfig,
    ExposureIntent,
    mkPlanExposureIntent,
    validExposureService,
    exposureIntentService,
    exposureIntentTargetHost,
    exposureIntentTargetPort,
    withPlanOwnedClusterConfig,
    planOwnedClusterConfigBase,
    planOwnedClusterConfigDriver,
    planOwnedClusterConfigBytes,
    planOwnedClusterConfigDigest,
    planOwnedClusterConfigStatePath,
    planOwnedRenderedConfigPath,
    planOwnedClusterConfigExposureIntents,
    planOwnedClusterConfigNodeMappings,
    planOwnedClusterConfigWorkloadSlice,
    withPlanOwnedClusterPreparation,
    planOwnedClusterName,
    planOwnedClusterDriver,
    planOwnedClusterStateDirectory,
    planOwnedClusterDurableRoot,
    planOwnedClusterConfigPath,
    planOwnedClusterPlacement,
    planOwnedClusterProviderKey,
    planOwnedClusterOwnershipIdentity,
    planOwnedClusterBudget,
    planOwnedClusterNodeNames,
    AcceleratorDaemonPlacement (..),
    AcceleratorIngressPlan (ClusterIpIngress, NodePortIngress),
    ingressServiceType,
    ingressServicePort,
    ingressNodePort,
    ingressKindListenAddress,
    TeardownKind (..),
    durableDataPath,
    ensureDurableDataPath,
    profileDataSegments,
    profileDataPath,
    profileFromPlanName,
    ensureProfileDataPath,
    resolvePlan,
    resolvePlanWithDriver,
    clusterRuntimeStateDirectory,
    clusterKubeconfigPath,
    resolveAcceleratorPlan,
    clusterDriverForSubstrate,
    acceleratorIngressPlan,
    nvidiaRuntimeProbeArgs,
    nvidiaRuntimeProbeReady,
    nvidiaRuntimeClassProbeArgs,
    nvidiaRuntimeClassObserved,
    nvidiaDevicePluginHelmArgs,
    nvidiaDevicePluginReadyArgs,
    nvidiaAllocatableProbeArgs,
    nvidiaAllocatableReady,
    NvidiaDevicePluginOps (..),
    ensureNvidiaDevicePluginWith,
    clusterNodeNames,
    clusterNodeCordonArgs,
    teardown,
)
where

import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Bifunctor (first)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Char (isAlphaNum, isAscii)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Cluster.Budget (
    ResourceSlice,
    resourceSliceBudget,
    resourceSliceFrame,
    resourceSliceName,
 )
import HostBootstrap.Cluster.Command (ClusterDriver (..))
import HostBootstrap.Cluster.Cordon (
    budgetFromResources,
    clusterNodeBudgetShare,
    renderQuantityError,
 )
import HostBootstrap.Cluster.Cordon.Foundation (ResourceBudget, kindNodeCordonArgsForBudget)
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.Ensure (reportedGpu)
import qualified HostBootstrap.Ensure.Cuda as Cuda
import HostBootstrap.Lifecycle.Execution.Internal (
    StepExecution,
    executionNodeDependencies,
    executionNodeFrame,
    executionNodeOperationKey,
    planExecutionPackageNode,
    planExecutionPackageProfile,
    planExecutionPackageProject,
    planExecutionPackageRoot,
    stepExecutionPackage,
    stepExecutionPlanDigest,
 )
import HostBootstrap.Network.Port (Port, mkPort)
import HostBootstrap.ProjectPlan (
    ClusterResource,
    DerivedTopology,
    PlannedResource,
    ProjectPlan,
    ProviderResource,
    plannedResourceFrame,
    plannedResourceKey,
    projectPlanProfileName,
    projectPlanProjectName,
    renderSnapshot,
    stablePlanSnapshotDigest,
    stablePlanSnapshotRoot,
    topology,
    topologyContainsFrame,
    topologyDescentEdges,
    topologyFrameOrder,
    topologyParentEdges,
    topologyParentFrame,
    withPlannedEdge,
 )
import HostBootstrap.Substrate (Substrate (substrateName), SubstrateName (LinuxGpu))
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath (dropTrailingPathSeparator, equalFilePath, isAbsolute, normalise, splitDirectories, takeDirectory, (</>))

{- | The cluster profile: production uses fixed names and the canonical @.data@
path; the test profile isolates each case under its own paths so a
harness-driven test never collides with a production cluster.
-}
data ClusterProfile = Production | TestCase String
    deriving (Eq, Show)

{- | The cluster creator used by a plan. The standard path creates a plain kind
cluster. The Linux GPU accelerator path creates the cluster through @nvkind@ so
worker nodes are GPU-enabled, while the rest of the lifecycle still talks to
the resulting kind cluster through @kind@/@kubectl@.
-}

{- | A resolved cluster plan: the kind cluster name, the durable state path
teardown never enumerates for removal (@.data@ under 'Production',
@.test_data\/\<case\>@ under 'TestCase'), the derived state safe to remove on
@delete@, and the closed fact that cluster rendering never publishes host
ports. Local endpoints are runtime-owned relay results, so both production and
test-case clusters create without host-port bindings and can coexist without
preselecting or colliding on host ports.
-}
data ClusterPlan = ClusterPlan
    { clusterName :: String
    , dataPath :: FilePath
    , derivedStatePath :: FilePath
    , clusterDriver :: ClusterDriver
    , clusterConfigFile :: Maybe FilePath
    , clusterNodeSuffixes :: [String]
    }
    deriving (Eq, Show)

{- | The coordinates conditional cluster release may read.

This ordinary data describes one resolved plan and grants no ownership
capability. The protected transaction still recovers the claim and compares
bound runtime identities before deletion. The durable root is not retained.
-}
data RetainedClusterProjection = RetainedClusterProjection String [String] FilePath FilePath
    deriving (Eq, Show)

-- | Derive all retained cleanup coordinates from the same resolved plan.
retainedClusterProjection :: ClusterPlan -> RetainedClusterProjection
retainedClusterProjection plan =
    RetainedClusterProjection
        (clusterName plan)
        (clusterNodeNames plan)
        (clusterRuntimeStateDirectory plan)
        (clusterKubeconfigPath plan)

retainedClusterName :: RetainedClusterProjection -> String
retainedClusterName (RetainedClusterProjection name _ _ _) = name

retainedClusterNodeNames :: RetainedClusterProjection -> [String]
retainedClusterNodeNames (RetainedClusterProjection _ nodes _ _) = nodes

retainedClusterStateDirectory :: RetainedClusterProjection -> FilePath
retainedClusterStateDirectory (RetainedClusterProjection _ _ directory _) = directory

retainedClusterKubeconfigPath :: RetainedClusterProjection -> FilePath
retainedClusterKubeconfigPath (RetainedClusterProjection _ _ _ kubeconfig) = kubeconfig

-- | Structural refusal while joining an exact plan-owned cluster package.
data ClusterPackageError
    = ClusterPackageMismatch Text
    deriving (Eq, Show)

{- | The complete cluster package retained by the exact consumer.

Its constructor is private and every identity parameter has a nominal role.
Consequently a cluster resource, provider dependency, topology, or budget slice
from another admission cannot be relabelled into this package.  The descriptive
driver vocabulary is derived once from the admitted plan and is never accepted
again as independent caller input.
-}
data
    PlanOwnedCluster
        scope
        specDigest
        planId
        configId
        cfg
        clusterId
        clusterFrame
        providerId
        providerFrame
        budgetId
        provider
        capabilityId
        wallSpecId
        workloadSetId
        partitionId
    = PlanOwnedCluster
        (ProjectPlan scope specDigest planId configId cfg)
        (PlannedResource scope planId clusterId ClusterResource clusterFrame)
        (PlannedResource scope planId providerId ProviderResource providerFrame)
        (DerivedTopology scope planId)
        ( ResourceSlice
            scope
            planId
            budgetId
            provider
            capabilityId
            wallSpecId
            workloadSetId
            partitionId
            clusterFrame
            clusterId
        )
        ClusterPlan
        Text
        (Text, Text)
    | ExecutionOwnedCluster
        (StepExecution scope planId)
        (PlannedResource scope planId clusterId ClusterResource clusterFrame)
        (PlannedResource scope planId providerId ProviderResource providerFrame)
        ( ResourceSlice
            scope
            planId
            budgetId
            provider
            capabilityId
            wallSpecId
            workloadSetId
            partitionId
            clusterFrame
            clusterId
        )
        ClusterPlan
        Text
        (Text, Text)

type role PlanOwnedCluster nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

{- | Exact rendered configuration attached to one admitted cluster package.

The constructor is hidden. The value retains every descriptive input that a
backend may observe, so preparation cannot select a driver or reread an
independently resolved configuration.
-}
data PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId
    = PlanOwnedClusterConfig
        (PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId)
        ClusterDriver
        ByteString
        Text
        FilePath
        FilePath
        [ExposureIntent]
        [(Text, Text)]
        [Text]

type role PlanOwnedClusterConfig nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

data ExposureIntent = ExposureIntent Text Text Port
    deriving (Eq, Show)

-- | One service grammar for intent construction and managed-record readback.
validExposureService :: Text -> Bool
validExposureService service =
    not (T.null service)
        && T.length service <= 128
        && not (T.any (`elem` ['\0', '/', '\\', ':', '\n', '\r', '\t']) service)

mkPlanExposureIntent :: Text -> Text -> Int -> Either ClusterPackageError ExposureIntent
mkPlanExposureIntent service target port
    | not (validExposureService service) = Left (ClusterPackageMismatch "the exposure service identity is invalid")
    | T.null target || T.any (`elem` ['/', '\\', ':', '\n', '\r', '\t', ' ']) target = Left (ClusterPackageMismatch "the exposure target host is invalid")
    | otherwise = case mkPort port of
        Nothing -> Left (ClusterPackageMismatch "the exposure target port is outside 1..65535")
        Just admitted -> Right (ExposureIntent service target admitted)

exposureIntentService :: ExposureIntent -> Text
exposureIntentService (ExposureIntent service _ _) = service

exposureIntentTargetHost :: ExposureIntent -> Text
exposureIntentTargetHost (ExposureIntent _ target _) = target

exposureIntentTargetPort :: ExposureIntent -> Port
exposureIntentTargetPort (ExposureIntent _ _ port) = port

{- | Join the one admitted plan to its exact cluster resource, direct provider
dependency, retained topology, and cluster budget slice.

The shared indices do the cross-plan work statically.  The term checks defend
the module boundary as well: the supplied topology must be the plan projection,
the resource frames must describe the direct placement edge, and the slice must
name the exact cluster resource in that frame.
-}
withPlanOwnedCluster ::
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId clusterId ClusterResource clusterFrame ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    DerivedTopology scope planId ->
    ResourceSlice
        scope
        planId
        budgetId
        provider
        capabilityId
        wallSpecId
        workloadSetId
        partitionId
        clusterFrame
        clusterId ->
    ClusterDriver ->
    Either
        ClusterPackageError
        ( PlanOwnedCluster
            scope
            specDigest
            planId
            configId
            cfg
            clusterId
            clusterFrame
            providerId
            providerFrame
            budgetId
            provider
            capabilityId
            wallSpecId
            workloadSetId
            partitionId
        )
withPlanOwnedCluster plan cluster provider suppliedTopology slice driver = do
    requirePackage
        "the supplied topology is not the exact topology projected by the project plan"
        (sameTopology suppliedTopology (topology plan))
    requirePackage
        "the cluster resource frame is outside the supplied topology"
        (topologyContainsFrame suppliedTopology (plannedResourceFrame cluster))
    requirePackage
        "the provider resource frame is outside the supplied topology"
        (topologyContainsFrame suppliedTopology (plannedResourceFrame provider))
    requirePackage
        "the cluster is not placed directly inside the supplied provider frame"
        (topologyParentFrame suppliedTopology (plannedResourceFrame cluster) == Just (plannedResourceFrame provider))
    case withPlannedEdge plan cluster provider (const ()) of
        Left _ -> Left (ClusterPackageMismatch "the provider is not the cluster resource's declared dependency")
        Right () -> Right ()
    requirePackage
        "the supplied budget slice belongs to another cluster resource"
        ( resourceSliceName slice == T.unpack (plannedResourceKey cluster)
            && resourceSliceFrame slice == T.unpack (plannedResourceFrame cluster)
        )
    let snapshot = renderSnapshot plan
        root = stablePlanSnapshotRoot snapshot
        profileName = projectPlanProfileName plan
    profile <- profileFromPlanName profileName
    let resolved = absolutizeClusterConfig root (resolvePlanWithDriver (T.unpack (projectPlanProjectName plan)) root profile driver)
        placement = (plannedResourceFrame provider, plannedResourceFrame cluster)
        owner = stablePlanSnapshotDigest snapshot <> ":" <> plannedResourceKey cluster
    Right (PlanOwnedCluster plan cluster provider suppliedTopology slice resolved owner placement)
  where
    sameTopology left right =
        topologyFrameOrder left == topologyFrameOrder right
            && topologyParentEdges left == topologyParentEdges right
            && topologyDescentEdges left == topologyDescentEdges right
    requirePackage detail condition
        | condition = Right ()
        | otherwise = Left (ClusterPackageMismatch detail)

{- | Join the executing cluster node to the exact resource/dependency metadata
projected into its opaque descriptor. This is the action-side peer of
'withPlanOwnedCluster': it reconstructs no sibling plan and accepts no caller
plan digest, profile, project, root, frame, or dependency list.
-}
withExecutionOwnedCluster ::
    StepExecution scope planId ->
    PlannedResource scope planId clusterId ClusterResource clusterFrame ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId clusterFrame clusterId ->
    ClusterDriver ->
    Either ClusterPackageError (PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId)
withExecutionOwnedCluster execution cluster provider slice driver = do
    requirePackage "the executing node is not the exact cluster resource" (plannedResourceKey cluster == operation && plannedResourceFrame cluster == frame)
    requirePackage "the provider is not an exact dependency of the executing cluster node" ((plannedResourceKey provider, plannedResourceFrame provider) `elem` dependencies)
    requirePackage "the supplied budget slice belongs to another cluster resource" (resourceSliceName slice == T.unpack (plannedResourceKey cluster) && resourceSliceFrame slice == T.unpack frame)
    profile <- profileFromPlanName (planExecutionPackageProfile package)
    let resolved = absolutizeClusterConfig (planExecutionPackageRoot package) (resolvePlanWithDriver (T.unpack (planExecutionPackageProject package)) (planExecutionPackageRoot package) profile driver)
        owner = stepExecutionPlanDigest execution <> ":" <> plannedResourceKey cluster
    pure (ExecutionOwnedCluster execution cluster provider slice resolved owner (plannedResourceFrame provider, frame))
  where
    package = stepExecutionPackage execution
    node = planExecutionPackageNode package
    operation = executionNodeOperationKey node
    frame = executionNodeFrame node
    dependencies = executionNodeDependencies node
    requirePackage detail condition
        | condition = Right ()
        | otherwise = Left (ClusterPackageMismatch detail)

{- | Bind canonical rendered output to an already joined plan-owned cluster.

The driver is selected when the plan or execution joins its cluster declaration.
The binder derives that retained driver, paths and node identities from the base package. Callers may submit rendered material for checking, but cannot choose an
independent cluster name, durable root, or placement.
-}
withPlanOwnedClusterConfig ::
    PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
    ByteString ->
    Text ->
    FilePath ->
    FilePath ->
    [ExposureIntent] ->
    [(Text, Text)] ->
    [Text] ->
    (PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> result) ->
    Either ClusterPackageError result
withPlanOwnedClusterConfig base bytes suppliedDigest suppliedState suppliedPath intents mappings workload consume = do
    requireConfig (not (nullBytes bytes)) "the canonical cluster config is empty"
    requireConfig (ByteString.length bytes <= 1048576) "the canonical cluster config exceeds 1 MiB"
    requireConfig (suppliedDigest == digestBytes bytes) "the canonical cluster config digest disagrees with its bytes"
    requireConfig (suppliedState == expectedState) "the cluster state path disagrees with the plan-owned durable root and driver"
    requireConfig (suppliedPath == expectedPath) "the cluster config path disagrees with the plan-owned durable root and driver"
    requireConfig (not ("hostPort:" `ByteString.isInfixOf` bytes)) "the canonical cluster config contains a host port"
    requireConfig (not ("extraPortMappings:" `ByteString.isInfixOf` bytes)) "the canonical cluster config contains host publication"
    requireConfig (not (null intents)) "the semantic exposure intent set is empty"
    requireConfig (unique (map exposureIntentService intents)) "the semantic exposure intent set contains a duplicate service"
    requireConfig (mappings == expectedMappings) "the node mapping disagrees with the closed driver"
    requireConfig (not (null workload) && unique workload) "the workload slice is empty or contains a duplicate"
    pure (consume (PlanOwnedClusterConfig adjusted driver bytes suppliedDigest suppliedState suppliedPath intents mappings workload))
  where
    driver = clusterDriver (planOwnedClusterResolvedPlan base)
    durableRoot = planOwnedClusterDurableRoot base
    expectedState = clusterRuntimeStateDirectoryFor driver durableRoot
    expectedPath = takeDirectory expectedState </> "config.yaml"
    expectedMappings =
        [ (T.pack suffix, T.pack (planOwnedClusterName base ++ "-" ++ suffix))
        | suffix <- driverNodeSuffixes driver
        ]
    adjusted = setPlanOwnedClusterRendering suppliedState suppliedPath base
    unique values = length values == length (nub values)
    nullBytes = ByteString.null
    digestBytes = TextEncoding.decodeUtf8 . convertToBase Base16 . (hash :: ByteString -> Digest SHA256)
    requireConfig condition detail
        | condition = Right ()
        | otherwise = Left (ClusterPackageMismatch detail)

setPlanOwnedClusterRendering ::
    FilePath ->
    FilePath ->
    PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
    PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId
setPlanOwnedClusterRendering statePath configPath (PlanOwnedCluster plan cluster provider topologyProjection slice resolved owner placement) =
    PlanOwnedCluster
        plan
        cluster
        provider
        topologyProjection
        slice
        resolved
            { derivedStatePath = statePath
            , clusterConfigFile = Just configPath
            }
        owner
        placement
setPlanOwnedClusterRendering statePath configPath (ExecutionOwnedCluster execution cluster provider slice resolved owner placement) =
    ExecutionOwnedCluster execution cluster provider slice resolved{derivedStatePath = statePath, clusterConfigFile = Just configPath} owner placement

planOwnedClusterConfigBase :: PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId
planOwnedClusterConfigBase (PlanOwnedClusterConfig base _ _ _ _ _ _ _ _) = base

planOwnedClusterConfigDriver :: PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> ClusterDriver
planOwnedClusterConfigDriver (PlanOwnedClusterConfig _ driver _ _ _ _ _ _ _) = driver

planOwnedClusterConfigBytes :: PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> ByteString
planOwnedClusterConfigBytes (PlanOwnedClusterConfig _ _ bytes _ _ _ _ _ _) = bytes

planOwnedClusterConfigDigest :: PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> Text
planOwnedClusterConfigDigest (PlanOwnedClusterConfig _ _ _ digest _ _ _ _ _) = digest

planOwnedClusterConfigStatePath :: PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> FilePath
planOwnedClusterConfigStatePath (PlanOwnedClusterConfig _ _ _ _ statePath _ _ _ _) = statePath

planOwnedRenderedConfigPath :: PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> FilePath
planOwnedRenderedConfigPath (PlanOwnedClusterConfig _ _ _ _ _ configPath _ _ _) = configPath

planOwnedClusterConfigExposureIntents :: PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> [ExposureIntent]
planOwnedClusterConfigExposureIntents (PlanOwnedClusterConfig _ _ _ _ _ _ intents _ _) = intents

planOwnedClusterConfigNodeMappings :: PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> [(Text, Text)]
planOwnedClusterConfigNodeMappings (PlanOwnedClusterConfig _ _ _ _ _ _ _ mappings _) = mappings

planOwnedClusterConfigWorkloadSlice :: PlanOwnedClusterConfig scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> [Text]
planOwnedClusterConfigWorkloadSlice (PlanOwnedClusterConfig _ _ _ _ _ _ _ _ workload) = workload

withPlanOwnedClusterPreparation ::
    PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId ->
    (ProjectPlan scope specDigest planId configId cfg -> PlannedResource scope planId clusterId ClusterResource clusterFrame -> result) ->
    (StepExecution scope planId -> PlannedResource scope planId clusterId ClusterResource clusterFrame -> result) ->
    result
withPlanOwnedClusterPreparation (PlanOwnedCluster plan cluster _ _ _ _ _ _) fromPlan _ = fromPlan plan cluster
withPlanOwnedClusterPreparation (ExecutionOwnedCluster execution cluster _ _ _ _ _) _ fromExecution = fromExecution execution cluster

-- | Admit the bounded, path-safe run key used by a Harness profile.
mkTestCaseProfile :: Text -> Either ClusterPackageError ClusterProfile
mkTestCaseProfile runKey
    | validHarnessRunKey runKey = Right (TestCase (T.unpack runKey))
    | otherwise = Left (ClusterPackageMismatch "the admitted Harness profile carries an invalid run key")

-- | Project a Harness run key without exposing its constructor.
clusterProfileRunKey :: ClusterProfile -> Maybe Text
clusterProfileRunKey Production = Nothing
clusterProfileRunKey (TestCase runKey) = Just (T.pack runKey)

validHarnessRunKey :: Text -> Bool
validHarnessRunKey runKey =
    not (T.null runKey)
        && T.length runKey <= 48
        && T.all (\character -> isAscii character && (isAlphaNum character || character == '-')) runKey

profileFromPlanName :: Text -> Either ClusterPackageError ClusterProfile
profileFromPlanName "production" = Right Production
profileFromPlanName profileName =
    case T.stripPrefix "harness:" profileName of
        Just runKey -> mkTestCaseProfile runKey
        Nothing -> Left (ClusterPackageMismatch "the admitted plan carries an unknown lifecycle profile")

absolutizeClusterConfig :: FilePath -> ClusterPlan -> ClusterPlan
absolutizeClusterConfig root resolved =
    resolved
        { clusterConfigFile = fmap (root </>) (clusterConfigFile resolved)
        }

{- | The resolved plan either owner carries.

Both constructors hold one, at different positions, and every accessor below
reads it. Eliminating the two positions once is what keeps an accessor from
being written twice and the two copies from drifting.
-}
planOwnedClusterDriver :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> ClusterDriver
planOwnedClusterDriver = clusterDriver . planOwnedClusterResolvedPlan

planOwnedClusterResolvedPlan :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> ClusterPlan
planOwnedClusterResolvedPlan (PlanOwnedCluster _ _ _ _ _ resolved _ _) = resolved
planOwnedClusterResolvedPlan (ExecutionOwnedCluster _ _ _ _ resolved _ _) = resolved

planOwnedClusterName :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> String
planOwnedClusterName = clusterName . planOwnedClusterResolvedPlan

planOwnedClusterStateDirectory :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> FilePath
planOwnedClusterStateDirectory = derivedStatePath . planOwnedClusterResolvedPlan

planOwnedClusterDurableRoot :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> FilePath
planOwnedClusterDurableRoot = dataPath . planOwnedClusterResolvedPlan

planOwnedClusterConfigPath :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> Maybe FilePath
planOwnedClusterConfigPath = clusterConfigFile . planOwnedClusterResolvedPlan

planOwnedClusterPlacement :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> (Text, Text)
planOwnedClusterPlacement (PlanOwnedCluster _ _ _ _ _ _ _ placement) = placement
planOwnedClusterPlacement (ExecutionOwnedCluster _ _ _ _ _ _ placement) = placement

planOwnedClusterProviderKey :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> Text
planOwnedClusterProviderKey (PlanOwnedCluster _ _ provider _ _ _ _ _) = plannedResourceKey provider
planOwnedClusterProviderKey (ExecutionOwnedCluster _ _ provider _ _ _ _) = plannedResourceKey provider

planOwnedClusterOwnershipIdentity :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> Text
planOwnedClusterOwnershipIdentity (PlanOwnedCluster _ _ _ _ _ _ owner _) = owner
planOwnedClusterOwnershipIdentity (ExecutionOwnedCluster _ _ _ _ _ owner _) = owner

planOwnedClusterBudget :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> ResourceBudget
planOwnedClusterBudget (PlanOwnedCluster _ _ _ _ slice _ _ _) = resourceSliceBudget slice
planOwnedClusterBudget (ExecutionOwnedCluster _ _ _ slice _ _ _) = resourceSliceBudget slice

planOwnedClusterNodeNames :: PlanOwnedCluster scope specDigest planId configId cfg clusterId clusterFrame providerId providerFrame budgetId provider capabilityId wallSpecId workloadSetId partitionId -> [String]
planOwnedClusterNodeNames = clusterNodeNames . planOwnedClusterResolvedPlan

-- | Resolve a cluster plan for a project, rooted at @root@, under a profile.
resolvePlan :: String -> FilePath -> ClusterProfile -> ClusterPlan
resolvePlan project root profile = resolvePlanWithDriver project root profile KindDriver

{- | Resolve a cluster plan with an explicit driver. Most callers use
'resolvePlan'; accelerator topology code selects 'NvkindDriver' for Linux GPU.

The resolved plan names no configuration template. Which template a cluster is
created from is the /project's/ decision and not this library's: the templates
are files in a project's own source root, and the choice between them turns on
where that project places its accelerator daemon rather than on the driver.
A plan therefore carries 'Nothing' here — the driver's own default topology —
until the project that ships a template names it.
-}
resolvePlanWithDriver :: String -> FilePath -> ClusterProfile -> ClusterDriver -> ClusterPlan
resolvePlanWithDriver project root profile driver = case profile of
    Production ->
        ClusterPlan
            { clusterName = project
            , dataPath = durableDataPathFor profile root
            , derivedStatePath = root </> ".cluster" </> project
            , clusterDriver = driver
            , clusterConfigFile = Nothing
            , clusterNodeSuffixes = driverNodeSuffixes driver
            }
    TestCase caseId ->
        ClusterPlan
            { clusterName = project ++ "-test-" ++ caseId
            , dataPath = durableDataPathFor profile root
            , derivedStatePath = root </> ".cluster" </> (project ++ "-test-" ++ caseId)
            , clusterDriver = driver
            , clusterConfigFile = Nothing
            , clusterNodeSuffixes = driverNodeSuffixes driver
            }

-- | The durable, driver-specific authority directory for one resolved cluster.
clusterRuntimeStateDirectory :: ClusterPlan -> FilePath
clusterRuntimeStateDirectory plan =
    clusterRuntimeStateDirectoryFor (clusterDriver plan) (dataPath plan)

-- | The kubeconfig written and owned beside the cluster authority records.
clusterKubeconfigPath :: ClusterPlan -> FilePath
clusterKubeconfigPath plan = clusterRuntimeStateDirectory plan </> "cluster.kubeconfig"

clusterRuntimeStateDirectoryFor :: ClusterDriver -> FilePath -> FilePath
clusterRuntimeStateDirectoryFor driver durableRoot =
    durableRoot </> "cluster" </> driverName </> "state"
  where
    driverName = case driver of
        KindDriver -> "kind"
        NvkindDriver -> "nvkind"
driverNodeSuffixes :: ClusterDriver -> [String]
driverNodeSuffixes KindDriver = ["control-plane"]
driverNodeSuffixes NvkindDriver = ["control-plane", "worker"]

{- | Resolve the accelerator cluster driver from the host substrate. Linux GPU is
direct-host @nvkind@; every other substrate keeps the existing kind path.
-}
clusterDriverForSubstrate :: Substrate -> ClusterDriver
clusterDriverForSubstrate sub
    | substrateName sub == LinuxGpu = NvkindDriver
    | otherwise = KindDriver

resolveAcceleratorPlan :: String -> FilePath -> ClusterProfile -> Substrate -> ClusterPlan
resolveAcceleratorPlan project root profile sub =
    resolvePlanWithDriver project root profile (clusterDriverForSubstrate sub)

-- | Where an accelerator daemon is placed relative to the web service.
data AcceleratorDaemonPlacement = InClusterDaemon | HostResidentDaemon
    deriving (Eq, Show)

{- | The web-service accelerator ingress exposure selected for a daemon
placement.

One case per Kubernetes service type, each carrying exactly what that type has.
An in-cluster daemon is reached through a normal @ClusterIP@ service and has no
node port and no host mapping to carry; a host-resident daemon is reached
through a @NodePort@ and therefore has both. Writing that as one record with a
type string and two optional fields left the invalid combinations — a
@ClusterIP@ with a node port, a @NodePort@ without one — constructible by any
consumer, with only prose saying they were wrong (§ HH).
-}
data AcceleratorIngressPlan
    = -- | reached inside the cluster: the service port, and nothing else
      ClusterIpIngress Int
    | {- | reached from the host: the service port, the node port, and the
      address the kind mapping listens on
      -}
      NodePortIngress Int Int String
    deriving (Eq, Show)

acceleratorIngressPlan :: AcceleratorDaemonPlacement -> Int -> Int -> AcceleratorIngressPlan
acceleratorIngressPlan InClusterDaemon servicePort _nodePort = ClusterIpIngress servicePort
acceleratorIngressPlan HostResidentDaemon servicePort nodePort =
    NodePortIngress servicePort nodePort "127.0.0.1"

-- | The Kubernetes service type this ingress renders as.
ingressServiceType :: AcceleratorIngressPlan -> String
ingressServiceType (ClusterIpIngress _) = "ClusterIP"
ingressServiceType NodePortIngress{} = "NodePort"

-- | The service port, which every case has.
ingressServicePort :: AcceleratorIngressPlan -> Int
ingressServicePort (ClusterIpIngress servicePort) = servicePort
ingressServicePort (NodePortIngress servicePort _ _) = servicePort

-- | The node port, which only the @NodePort@ case has.
ingressNodePort :: AcceleratorIngressPlan -> Maybe Int
ingressNodePort (ClusterIpIngress _) = Nothing
ingressNodePort (NodePortIngress _ nodePort _) = Just nodePort

-- | The kind host mapping's listen address, which only the @NodePort@ case has.
ingressKindListenAddress :: AcceleratorIngressPlan -> Maybe String
ingressKindListenAddress (ClusterIpIngress _) = Nothing
ingressKindListenAddress (NodePortIngress _ _ listenAddress) = Just listenAddress

-- | The kind of teardown.
data TeardownKind = Down | Delete
    deriving (Eq, Show)

-- | The canonical host-owned durable root for a production project.
durableDataPath :: FilePath -> FilePath
durableDataPath root = durableDataPathFor Production root

{- | The durable state root's path segments for one profile, relative to the
project root.

This is the __one__ definition of where a run's durable state lives, and
'resolvePlanWithDriver' derives a plan's @dataPath@ from it. A production run
owns the never-removed @.data@; a harness run owns the @.test_data\/\<run\>@
generation its ownership bracket already holds under all four ownership clauses.
Keeping it here, as segments, is what lets a caller that needs a
'HostBootstrap.ProjectRoot.CanonicalHostPath' derive the same location the plan
preserves rather than re-spelling it.
-}
profileDataSegments :: ClusterProfile -> [FilePath]
profileDataSegments Production = [".data"]
profileDataSegments (TestCase runName) = [".test_data", runName]

-- | The durable state root for one profile, under @root@.
profileDataPath :: ClusterProfile -> FilePath -> FilePath
profileDataPath = durableDataPathFor

durableDataPathFor :: ClusterProfile -> FilePath -> FilePath
durableDataPathFor profile root = foldl (</>) root (profileDataSegments profile)

{- | Ensure the canonical host-owned durable root exists and return its path.
Creating an existing directory is an idempotent no-op and never inspects or
removes its contents.
-}
ensureDurableDataPath :: FilePath -> IO FilePath
ensureDurableDataPath = ensureProfileDataPath Production

-- | 'ensureDurableDataPath' for one profile's own durable root.
ensureProfileDataPath :: ClusterProfile -> FilePath -> IO FilePath
ensureProfileDataPath profile root = do
    let path = profileDataPath profile root
    createDirectoryIfMissing True path
    pure path

{- | Partition a teardown into the paths to remove and the paths to preserve.
The @.data@ path is preserved under both @down@ and @delete@ — the
never-delete-@.data@ invariant — so it never appears in the removal set.
-}
teardown :: TeardownKind -> ClusterPlan -> Either Text ([FilePath], [FilePath])
teardown Down plan = Right ([], [dataPath plan, derivedStatePath plan])
teardown Delete plan
    | unsafeRemoval (derivedStatePath plan) (dataPath plan) =
        Left "cluster teardown: derived state may contain the durable root"
    | otherwise = Right ([derivedStatePath plan], [dataPath plan])

-- Refuse ambiguous lexical paths rather than guessing how their parents resolve.
unsafeRemoval :: FilePath -> FilePath -> Bool
unsafeRemoval removal durable =
    null removal || null durable || isAbsolute removal /= isAbsolute durable
        || any (== "..") (components removal <> components durable)
        || isAncestor (components removal) (components durable)
  where
    components = filter (/= ".") . map dropTrailingPathSeparator . splitDirectories . normalise
    isAncestor parent child =
        length parent <= length child && and (zipWith equalFilePath parent child)

{- | NVIDIA Docker runtime smoke used before the Linux GPU direct @nvkind@ path
asks Kubernetes to run CUDA daemon pods.
-}
nvidiaRuntimeProbeArgs :: [String]
nvidiaRuntimeProbeArgs = Cuda.nvkindRuntimeProbeArgs

nvidiaRuntimeProbeReady :: Either String (ExitCode, String, String) -> Bool
nvidiaRuntimeProbeReady = reportedGpu

-- | Read the exact RuntimeClass created by nvkind without making absence an API error.
nvidiaRuntimeClassProbeArgs :: [String]
nvidiaRuntimeClassProbeArgs =
    [ "get"
    , "runtimeclass"
    , "nvidia"
    , "--ignore-not-found"
    , "-o"
    , "jsonpath={.handler}"
    ]

{- | Classify nvkind's RuntimeClass observation. Absence is distinct from a
tool/API fault, while an unexpected handler is a foreign-object conflict.
-}
nvidiaRuntimeClassObserved :: Either String (ExitCode, String, String) -> Either String Bool
nvidiaRuntimeClassObserved (Left err) = Left ("NVIDIA RuntimeClass probe failed: " ++ err)
nvidiaRuntimeClassObserved (Right (ExitFailure code, _, err)) =
    Left ("NVIDIA RuntimeClass probe exited " ++ show code ++ ": " ++ err)
nvidiaRuntimeClassObserved (Right (ExitSuccess, out, _)) =
    case T.strip (T.pack out) of
        "" -> Right False
        "nvidia" -> Right True
        handler -> Left ("NVIDIA RuntimeClass conflict: expected handler nvidia, observed " ++ T.unpack handler)

{- | Pinned NVIDIA device-plugin install for an @nvkind@ cluster. The plugin is
what publishes @nvidia.com/gpu@ into node allocatable resources; creating the
GPU-enabled kind nodes alone is not sufficient for pod scheduling.
-}
nvidiaDevicePluginHelmArgs :: [String]
nvidiaDevicePluginHelmArgs =
    [ "upgrade"
    , "--install"
    , "nvidia-device-plugin"
    , "nvdp/nvidia-device-plugin"
    , "--version"
    , "0.19.3"
    , "--namespace"
    , "nvidia"
    , "--create-namespace"
    , "--set"
    , "runtimeClassName=nvidia"
    , "--wait"
    , "--timeout"
    , "3m"
    ]

nvidiaDevicePluginReadyArgs :: [String]
nvidiaDevicePluginReadyArgs =
    [ "rollout"
    , "status"
    , "daemonset/nvidia-device-plugin"
    , "-n"
    , "nvidia"
    , "--timeout=120s"
    ]

nvidiaAllocatableProbeArgs :: [String]
nvidiaAllocatableProbeArgs =
    [ "get"
    , "nodes"
    , "-o"
    , "jsonpath={range .items[*]}{.status.allocatable.nvidia\\.com/gpu}{\"\\n\"}{end}"
    ]

nvidiaAllocatableReady :: Either String (ExitCode, String, String) -> Bool
nvidiaAllocatableReady (Right (ExitSuccess, out, _)) = any positiveQuantity (lines out)
  where
    positiveQuantity raw = case reads raw of
        [(n, "")] -> n > (0 :: Integer)
        _ -> False
nvidiaAllocatableReady _ = False

{- | Injectable operations for the NVIDIA device-plugin reconciliation. Keeping
the control flow separate from the concrete Helm and kubectl calls makes the
idempotence contract directly testable: allocatable GPU capacity is probed
first, and a positive result must bypass every mutating/readiness operation.
-}
data NvidiaDevicePluginOps m = NvidiaDevicePluginOps
    { ndpProbeAllocatable :: m Bool
    , ndpReconcilePlugin :: m ()
    , ndpWaitPluginReady :: m ()
    , ndpRequireAllocatable :: m ()
    }

{- | Reconcile the NVIDIA device plugin only when the read-only pre-probe does
not already find positive allocatable GPU capacity. The post-reconcile
allocation requirement is deliberately a distinct final operation: a Ready
DaemonSet is not sufficient unless a node actually advertises
@nvidia.com/gpu@.
-}
ensureNvidiaDevicePluginWith :: (Monad m) => NvidiaDevicePluginOps m -> m ()
ensureNvidiaDevicePluginWith ops = do
    alreadyAllocatable <- ndpProbeAllocatable ops
    unless alreadyAllocatable $ do
        ndpReconcilePlugin ops
        ndpWaitPluginReady ops
        ndpRequireAllocatable ops

-- | The node containers the selected cluster driver creates.
clusterNodeNames :: ClusterPlan -> [String]
clusterNodeNames plan = map ((clusterName plan ++ "-") ++) (clusterNodeSuffixes plan)

{- | Split the one cluster envelope evenly across every node container, flooring
each dimension so the sum never exceeds the declared slice. An nvkind cluster
has a control-plane plus one GPU worker; giving the full envelope to both would
double-count the budget.
-}
clusterNodeCordonArgs :: ClusterPlan -> ResourceEnvelope -> Either String [[String]]
clusterNodeCordonArgs plan resources = do
    budget <- first renderQuantityError (budgetFromResources resources)
    let names = clusterNodeNames plan
    perNode <- clusterNodeBudgetShare (length names) budget
    traverse (`kindNodeCordonArgsForBudget` perNode) names

