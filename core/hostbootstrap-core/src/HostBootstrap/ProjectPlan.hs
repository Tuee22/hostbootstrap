{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | The pure public facade for the single indexed project plan.

Constructors stay in the hidden lifecycle-plan kernel.  This module exposes
only the authored and admitted type vocabulary plus the narrow bridge a
finalized static project specification uses to bind its already validated
steps to one exact root and validated configuration.
-}
module HostBootstrap.ProjectPlan
    ( PlanDraft
    , ProjectPlan
    , PlannedStep
    , OperationKey
    , operationKeyText
    , PlannedResource
    , ProviderResource
    , DurableShareResource
    , DurableAliasResource
    , DockerResource
    , MinioResource
    , RegistryResource
    , ClusterResource
    , ChartWorkloadResource
    , PlannedResourceKind (..)
    , PlannedEdge
    , DerivedTopology
    , StablePlanSnapshot
    , PlanError (..)
    , planDraftsFromValidatedBuilder
    , forward
    , plannedStepLabel
    , plannedStepFrameId
    , plannedStepFrameLabel
    , plannedStepOperationKey
    , plannedStepDependencyOperations
    , plannedStepProjectedOperationKeys
    , plannedStepIdentity
    , plannedStepRunsAfterHandoff
    , plannedStepReversePolicy
    , plannedStepReverseRun
    , PlannedStepObservation
    , plannedStepObservationSucceeded
    , plannedStepObservationDetail
    , plannedStepRefusalObservation
    , runPlannedStep
    , plannedResourceKey
    , plannedResourceFrame
    , plannedEdgeTargetKey
    , plannedEdgeDependencyKey
    , withPlannedResourceOfKind
    , withChartWorkloadResource
    , chartWorkloadResourceKey
    , chartWorkloadResourceFrame
    , chartWorkloadReverseIdentity
    , withPlannedEdge
    , withProviderGuestAliasProjection
    , withPlannedStepResourceOfKind
    , withPlannedStepGuestAliasProjection
    , topology
    , topologyFrameOrder
    , topologyParentEdges
    , topologyDescentEdges
    , topologyContainsFrame
    , topologyFrameLabel
    , topologyParentFrame
    , topologyDescentFrom
    , projectPlanProfileName
    , projectPlanProjectName
    , renderSnapshot
    , stablePlanSnapshotFormatVersion
    , stablePlanSnapshotRoot
    , stablePlanSnapshotSpecDigest
    , stablePlanSnapshotConfigDigest
    , stablePlanSnapshotBytes
    , stablePlanSnapshotDigest
    )
where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Word (Word64)
import HostBootstrap.Config.Schema
    ( ValidatedConfig
    , validatedConfigValue
    )
import HostBootstrap.Lifecycle.Execution (StepExecution)
import HostBootstrap.Lifecycle.Plan
    ( ChartWorkloadResource
    , ClusterResource
    , DerivedTopology
    , DockerResource
    , DurableAliasResource
    , DurableShareResource
    , MinioResource
    , PlanDraft
    , PlanError (..)
    , PlannedEdge
    , PlannedResource
    , PlannedResourceKind (..)
    , PlannedStep (..)
    , ProviderResource
    , ProjectPlan
    , RegistryResource
    , StablePlanSnapshot
    , forwardKernel
    , chartWorkloadResourceFrameKernel
    , chartWorkloadResourceKeyKernel
    , chartWorkloadReverseIdentityKernel
    , planDraftsFromValidatedStepPlanKernel
    , plannedStepDependencyOperationsKernel
    , plannedStepFrameIdKernel
    , plannedStepFrameLabelKernel
    , plannedStepLabelKernel
    , plannedStepOperationKeyKernel
    , plannedStepProjectedOperationKeysKernel
    , projectPlanProfileNameKernel
    , projectPlanProfileProjectNameKernel
    , plannedEdgeDependencyKeyKernel
    , plannedEdgeTargetKeyKernel
    , plannedResourceFrameKernel
    , plannedResourceKeyKernel
    , renderSnapshotKernel
    , runPlannedStepKernel
    , stablePlanSnapshotBytesKernel
    , stablePlanSnapshotConfigDigestKernel
    , stablePlanSnapshotDigestKernel
    , stablePlanSnapshotFormatVersionKernel
    , stablePlanSnapshotRootKernel
    , stablePlanSnapshotSpecDigestKernel
    , topologyContainsFrameKernel
    , topologyDescentEdgesKernel
    , topologyDescentFromKernel
    , topologyFrameLabelKernel
    , topologyFrameOrderKernel
    , topologyKernel
    , topologyParentEdgesKernel
    , topologyParentFrameKernel
    , withPlannedStepGuestAliasProjectionKernel
    , withPlannedStepResourceOfKindKernel
    , withProjectPlannedEdgeKernel
    , withProjectPlannedResourceOfKindKernel
    , withProjectChartWorkloadResourceKernel
    , withProjectProviderGuestAliasProjectionKernel
    )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lift.Context (LiftContext)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.Step
    ( CoreStepId (PostHandoffId)
    , OperationKey
    , ReversePolicy
    , StepIdentity (CoreStepIdentity)
    , StepObservation (..)
    , StepPlan
    , StepPlanError
    , TeardownAction
    , TeardownOutcome
    , operationKeyText
    , observationDetail
    , observationSucceeded
    , stepIdentity
    , stepReverse
    , stepReversePolicy
    )

{- | Bind one already validated non-empty step graph to the root and
configuration that produce it.

The finalized project-specification layer supplies its scope-polymorphic
builder to this bridge.  The bridge invokes it with the exact root and value
inside the validated configuration before binding the resulting non-empty
graph.  Consequently no raw root, specification digest, configuration digest,
or caller-labelled phantom enters the draft stream.
-}
planDraftsFromValidatedBuilder ::
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId config ->
    ( CanonicalProjectRoot scope rootId ->
      config ->
      Either StepPlanError StepPlan
    ) ->
    Either StepPlanError (NonEmpty (PlanDraft scope specDigest config))
planDraftsFromValidatedBuilder root config build =
    planDraftsFromValidatedStepPlanKernel root config
        <$> build root (validatedConfigValue config)

-- | The exact non-empty forward ordering of one admitted project plan.
forward ::
    ProjectPlan scope specDigest planId configId cfg ->
    NonEmpty (PlannedStep scope planId configId (cfg scope))
forward = forwardKernel

plannedStepLabel :: PlannedStep scope planId configId config -> Text
plannedStepLabel = plannedStepLabelKernel

plannedStepFrameId :: PlannedStep scope planId configId config -> Text
plannedStepFrameId = plannedStepFrameIdKernel

plannedStepFrameLabel :: PlannedStep scope planId configId config -> Text
plannedStepFrameLabel = plannedStepFrameLabelKernel

plannedStepOperationKey :: PlannedStep scope planId configId config -> OperationKey
plannedStepOperationKey = plannedStepOperationKeyKernel

{- | The node's exact ordered dependency prefix as @(operation key, frame)@
pairs.  It is descriptive plan data, not execution authority.
-}
plannedStepDependencyOperations ::
    PlannedStep scope planId configId config ->
    [(OperationKey, Text)]
plannedStepDependencyOperations = plannedStepDependencyOperationsKernel

plannedStepProjectedOperationKeys ::
    PlannedStep scope planId configId config ->
    [OperationKey]
plannedStepProjectedOperationKeys = plannedStepProjectedOperationKeysKernel

-- | Purely project this node's retained, validated step identity.
plannedStepIdentity ::
    PlannedStep scope planId configId config ->
    StepIdentity
plannedStepIdentity (PlannedStep _ step _) = stepIdentity step

-- | Whether this exact node belongs to its frame's post-descent suffix.
plannedStepRunsAfterHandoff ::
    PlannedStep scope planId configId config ->
    Bool
plannedStepRunsAfterHandoff plannedStep =
    case plannedStepIdentity plannedStep of
        CoreStepIdentity (PostHandoffId _) -> True
        _ -> False

-- | Purely project this node's retained reverse classification.
plannedStepReversePolicy ::
    PlannedStep scope planId configId config ->
    ReversePolicy
plannedStepReversePolicy (PlannedStep _ step _) = stepReversePolicy step

{- | Narrowly project this node's retained reverse callback, if any.

This projection does not run the callback; a reverse interpreter must still
supply the host configuration and authorized teardown action explicitly.
-}
plannedStepReverseRun ::
    PlannedStep scope planId configId config ->
    Maybe (HostConfig -> TeardownAction -> IO TeardownOutcome)
plannedStepReverseRun (PlannedStep _ step _) = stepReverse step

{- | One raw action observation paired back with the exact projected plan node
whose callback produced it.

The backend-facing 'StepObservation' remains deliberately plan-independent.
Only this facade can turn it into an interpreter observation, and all three
roles are nominal so the result cannot be relabelled onto another admitted
plan or configuration.
-}
type role PlannedStepObservation nominal nominal nominal
newtype PlannedStepObservation scope planId configId
    = PlannedStepObservation StepObservation

plannedStepObservationSucceeded ::
    PlannedStepObservation scope planId configId ->
    Bool
plannedStepObservationSucceeded (PlannedStepObservation observation) =
    observationSucceeded observation

plannedStepObservationDetail ::
    PlannedStepObservation scope planId configId ->
    Text
plannedStepObservationDetail (PlannedStepObservation observation) =
    observationDetail observation

-- | Pair a caught safety refusal with the exact node whose callback threw it.
plannedStepRefusalObservation ::
    PlannedStep scope planId configId config ->
    Text ->
    PlannedStepObservation scope planId configId
plannedStepRefusalObservation _ reason =
    PlannedStepObservation (StepRefused reason)

-- | Invoke the callback and retain its observation under the projected plan and configuration indices.
runPlannedStep ::
    PlannedStep scope planId configId config ->
    StepExecution scope planId ->
    IO (PlannedStepObservation scope planId configId)
runPlannedStep planned execution =
    PlannedStepObservation <$> runPlannedStepKernel planned execution

-- | The stable operation key projected for this exact planned resource.
plannedResourceKey ::
    PlannedResource scope planId resourceId resource frame ->
    Text
plannedResourceKey = plannedResourceKeyKernel

-- | The semantic frame identifier projected from the admitted graph.
plannedResourceFrame ::
    PlannedResource scope planId resourceId resource frame ->
    Text
plannedResourceFrame = plannedResourceFrameKernel

plannedEdgeTargetKey ::
    PlannedEdge scope planId targetId target targetFrame dependencyId dependency dependencyFrame ->
    Text
plannedEdgeTargetKey = plannedEdgeTargetKeyKernel

plannedEdgeDependencyKey ::
    PlannedEdge scope planId targetId target targetFrame dependencyId dependency dependencyFrame ->
    Text
plannedEdgeDependencyKey = plannedEdgeDependencyKeyKernel

{- | Project one closed resource family from the exact admitted plan.

The opaque operation key must itself come from a plan projection.  The plan
supplies the stable digest and frame and generates both local identities inside
the continuation.
-}
withPlannedResourceOfKind ::
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResourceKind resource ->
    OperationKey ->
    ( forall resourceId frame.
      PlannedResource scope planId resourceId resource frame ->
      result
    ) ->
    Either PlanError result
withPlannedResourceOfKind = withProjectPlannedResourceOfKindKernel

withChartWorkloadResource ::
    ProjectPlan scope specDigest planId configId cfg ->
    OperationKey ->
    (forall resourceId frame. ChartWorkloadResource scope planId resourceId frame -> result) ->
    Either PlanError result
withChartWorkloadResource = withProjectChartWorkloadResourceKernel

chartWorkloadResourceKey :: ChartWorkloadResource scope planId resourceId frame -> Text
chartWorkloadResourceKey = chartWorkloadResourceKeyKernel

chartWorkloadResourceFrame :: ChartWorkloadResource scope planId resourceId frame -> Text
chartWorkloadResourceFrame = chartWorkloadResourceFrameKernel

chartWorkloadReverseIdentity :: ChartWorkloadResource scope planId resourceId frame -> (Text, Text, Text)
chartWorkloadReverseIdentity = chartWorkloadReverseIdentityKernel

-- | Prove the exact dependency relation between two resources of this plan.
withPlannedEdge ::
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId targetId target targetFrame ->
    PlannedResource scope planId dependencyId dependency dependencyFrame ->
    ( PlannedEdge
        scope
        planId
        targetId
        target
        targetFrame
        dependencyId
        dependency
        dependencyFrame ->
      result
    ) ->
    Either PlanError result
withPlannedEdge = withProjectPlannedEdgeKernel

{- | Project the declared provider-guest alias from the same validated graph
that produced its provider and durable-share resources.
-}
withProviderGuestAliasProjection ::
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ( forall aliasId.
      PlannedResource scope planId aliasId DurableAliasResource shareFrame ->
      PlannedEdge
        scope
        planId
        aliasId
        DurableAliasResource
        shareFrame
        shareId
        DurableShareResource
        shareFrame ->
      result
    ) ->
    Either PlanError result
withProviderGuestAliasProjection = withProjectProviderGuestAliasProjectionKernel

{- | Resolve only this node's own resource or one member of its exact ordered
dependency prefix.  No whole-plan lookup is available through a 'PlannedStep'.
-}
withPlannedStepResourceOfKind ::
    PlannedStep scope planId configId config ->
    PlannedResourceKind resource ->
    OperationKey ->
    ( forall resourceId frame.
      PlannedResource scope planId resourceId resource frame ->
      result
    ) ->
    Either PlanError result
withPlannedStepResourceOfKind = withPlannedStepResourceOfKindKernel

-- | Project the alias only from the node that declared that exact relation.
withPlannedStepGuestAliasProjection ::
    PlannedStep scope planId configId config ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ( forall aliasId.
      PlannedResource scope planId aliasId DurableAliasResource shareFrame ->
      PlannedEdge
        scope
        planId
        aliasId
        DurableAliasResource
        shareFrame
        shareId
        DurableShareResource
        shareFrame ->
      result
    ) ->
    Either PlanError result
withPlannedStepGuestAliasProjection = withPlannedStepGuestAliasProjectionKernel

-- | The exact non-empty frame topology projected from one admitted plan.
topology ::
    ProjectPlan scope specDigest planId configId cfg ->
    DerivedTopology scope planId
topology = topologyKernel

-- | Ordered non-empty @(frame id, presentation label)@ membership.
topologyFrameOrder :: DerivedTopology scope planId -> NonEmpty (Text, Text)
topologyFrameOrder = topologyFrameOrderKernel

-- | Ordered @(parent frame, child frame)@ edges.
topologyParentEdges :: DerivedTopology scope planId -> [(Text, Text)]
topologyParentEdges = topologyParentEdgesKernel

-- | Ordered @(parent frame, child frame, lift context)@ descent edges.
topologyDescentEdges ::
    DerivedTopology scope planId ->
    [(Text, Text, LiftContext)]
topologyDescentEdges = topologyDescentEdgesKernel

topologyContainsFrame :: DerivedTopology scope planId -> Text -> Bool
topologyContainsFrame = topologyContainsFrameKernel

topologyFrameLabel :: DerivedTopology scope planId -> Text -> Maybe Text
topologyFrameLabel = topologyFrameLabelKernel

topologyParentFrame :: DerivedTopology scope planId -> Text -> Maybe Text
topologyParentFrame = topologyParentFrameKernel

topologyDescentFrom ::
    DerivedTopology scope planId ->
    Text ->
    Maybe (Text, LiftContext)
topologyDescentFrom = topologyDescentFromKernel

-- | The exact lifecycle-profile identity retained when this plan was admitted.
-- This is a descriptive projection only; it grants no lifecycle authority.
projectPlanProfileName ::
    ProjectPlan scope specDigest planId configId cfg ->
    Text
projectPlanProfileName = projectPlanProfileNameKernel

-- | The installed-project identity retained when this plan was admitted.
-- Consumers use this projection when a provider-local name must be derived
-- from the plan rather than supplied independently by a caller.
projectPlanProjectName ::
    ProjectPlan scope specDigest planId configId cfg ->
    Text
projectPlanProjectName = projectPlanProfileProjectNameKernel

-- | The pure canonical, non-authorizing snapshot retained by one exact plan.
renderSnapshot ::
    ProjectPlan scope specDigest planId configId cfg ->
    StablePlanSnapshot
renderSnapshot = renderSnapshotKernel

stablePlanSnapshotFormatVersion :: StablePlanSnapshot -> Word64
stablePlanSnapshotFormatVersion = stablePlanSnapshotFormatVersionKernel

-- | The exact canonical project root retained in the stable bytes.
stablePlanSnapshotRoot :: StablePlanSnapshot -> FilePath
stablePlanSnapshotRoot = stablePlanSnapshotRootKernel

stablePlanSnapshotSpecDigest :: StablePlanSnapshot -> Text
stablePlanSnapshotSpecDigest = stablePlanSnapshotSpecDigestKernel

stablePlanSnapshotConfigDigest :: StablePlanSnapshot -> Text
stablePlanSnapshotConfigDigest = stablePlanSnapshotConfigDigestKernel

stablePlanSnapshotBytes :: StablePlanSnapshot -> ByteString
stablePlanSnapshotBytes = stablePlanSnapshotBytesKernel

stablePlanSnapshotDigest :: StablePlanSnapshot -> Text
stablePlanSnapshotDigest = stablePlanSnapshotDigestKernel
