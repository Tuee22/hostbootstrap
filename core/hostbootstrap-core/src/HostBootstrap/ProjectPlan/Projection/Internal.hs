{-# LANGUAGE NoMonoLocalBinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The one immediate-target projection kernel.

This boundary owns descriptor, context, configuration, and target-plan
validation for exactly one parent frame and its single declared descent.  It
holds no 'HostBootstrap.Lifecycle.Context.Internal.ValidatedLifecycleContext',
canonical root, protected store, journal, cursor, or process authority, so the
same kernel serves both the exact single-edge planned-forward package and the
recursive rooted plan catalog without either one borrowing the other's
retained lifecycle evidence.

Every check finishes before the rank-2 continuation runs, so a refusal cannot
create a handoff, session, or backend effect through this boundary.
-}
module HostBootstrap.ProjectPlan.Projection.Internal
    ( withImmediateTargetKernel
    )
where

import Data.ByteString (ByteString)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Config.Class (ProjectCfg (cfgContext))
import HostBootstrap.Config.Schema
    ( renderScopedProjectConfigBytes
    , validatedConfigDigest
    , validatedConfigSpecDigest
    , validatedConfigValue
    )
import HostBootstrap.Config.Vocab (Mount (..))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Handoff
    ( HandoffBindingInput (..)
    , HandoffPayloadKind (NarrowedProjectConfig)
    , childConfigDigest
    )
import HostBootstrap.Lifecycle.Plan
    ( PlanDigestBinding
    , ProjectPlan
    , canonicalProjectedRootKernel
    , planDigestBindingDigestKernel
    , projectPlanValidatedConfigKernel
    , topologyDescentEdgesKernel
    , topologyFrameOrderKernel
    , topologyKernel
    , topologyParentEdgesKernel
    , withProjectedProjectPlanKernel
    )
import HostBootstrap.Lift.Context
    ( ConfigDelivery (cdPayload)
    , ContainerLift (..)
    , LiftContext (..)
    , LiftLayer (..)
    )
import HostBootstrap.ProjectPlan.Construct.Internal
    ( FinalizedProjectSpec
    , finalizedProjectCodecKernel
    , withFinalizedForwardChildProjectionKernel
    )
import HostBootstrap.ProjectPlan.Frame
    ( CurrentFrame
    , currentFrameId
    , withCurrentFrame
    )

{- | Project the single declared descent of one exact parent frame.

The supplied current frame must be the admitted context's own endpoint, the
parent plan must retain exactly that context, the topology and placement must
be total, and the frame must declare exactly one one-layer forward edge.  The
fixed project-owned projector then yields the child descriptor, configuration,
and step plan; the target plan is admitted independently at that descriptor;
and the canonical payload, both digests, the ancestry prefixes, and the
selected lift are joined before the continuation receives any evidence.
-}
withImmediateTargetKernel ::
    (ProjectCfg cfg) =>
    FinalizedProjectSpec scope specDigest cfg ->
    ProjectPlan scope specDigest parentPlanId parentConfigId cfg ->
    CurrentFrame scope parentPlanId parentFrame ->
    Context.BinaryContext ->
    ( forall childPlanDigest childPlanId childConfigId childFrame.
      ProjectPlan scope specDigest childPlanId childConfigId cfg ->
      PlanDigestBinding scope specDigest childPlanDigest childPlanId ->
      CurrentFrame scope childPlanId childFrame ->
      Context.BinaryContext ->
      Text ->
      Text ->
      LiftContext ->
      LiftContext ->
      ByteString ->
      Text ->
      Text ->
      HandoffBindingInput ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withImmediateTargetKernel finalized parent suppliedCurrent parentContext use
    | parentFrameId /= Context.currentFrame parentContext =
        pure (refusal "parent frame evidence differs from its admitted context")
    | cfgContext (validatedConfigValue parentConfig) /= parentContext =
        pure (refusal "parent lifecycle context differs from the admitted plan")
    | otherwise =
        case (Context.validateTopology parentContext, Context.contextPlacement parentContext) of
            (Left failure, _) -> pure (Left (failureText "binary context" failure))
            (_, Left failure) -> pure (Left (failureText "binary context" failure))
            (Right (), Right placement) -> selectEdge placement
  where
    parentConfig = projectPlanValidatedConfigKernel parent
    parentFrameId = currentFrameId suppliedCurrent

    selectEdge placement =
        case
            [ (child, route)
            | (edgeParent, child, route) <- topologyDescentEdgesKernel (topologyKernel parent)
            , edgeParent == parentFrameId
            ]
        of
            [(child, rawRoute@(LiftContext [_]))] ->
                withFinalizedForwardChildProjectionKernel
                    finalized
                    parentConfig
                    parentFrameId
                    child
                    rawRoute
                    (admitProjection placement child rawRoute)
            [_] -> pure (refusal "the immediate topology edge is not one layer")
            [] -> pure (refusal "the current frame has no forward topology edge")
            _ -> pure (refusal "the current frame has multiple forward topology edges")

    admitProjection placement child rawRoute descriptor childConfig childPlan =
        case expectedChildContext placement parentContext descriptor rawRoute of
            Left failure -> pure (Left failure)
            Right expected
                | cfgContext (validatedConfigValue childConfig) /= expected ->
                    pure (refusal "projected child context differs from the exact derived context")
                | Context.sourceRoot expected /= Text.pack descriptor ->
                    pure (refusal "projected child source root differs from its descriptor")
                | Context.currentFrame expected /= child ->
                    pure (refusal "projected child context does not end at the selected child")
                | otherwise ->
                    let payload =
                            renderScopedProjectConfigBytes
                                (finalizedProjectCodecKernel finalized)
                                (validatedConfigValue childConfig)
                     in if childConfigDigest payload /= validatedConfigDigest childConfig
                            then pure (refusal "canonical child payload digest differs")
                            else
                                case withProjectedProjectPlanKernel parent descriptor childConfig childPlan
                                    (sealTarget placement expected child rawRoute payload childConfig) of
                                    Left failure -> pure (Left (failureText "projected plan" failure))
                                    Right action -> action

    sealTarget placement expected child rawRoute payload childConfig targetPlan binding =
        case validatePlanPrefixes parent targetPlan expected placement of
            Left failure -> pure (Left failure)
            Right () -> case containerPayloadMatches rawRoute payload of
                Left failure -> pure (Left failure)
                Right () ->
                    case withCurrentFrame targetPlan expected $ \targetCurrent _ _ ->
                        use
                            targetPlan
                            binding
                            targetCurrent
                            expected
                            parentFrameId
                            child
                            rawRoute
                            (withoutConfigDelivery rawRoute)
                            payload
                            (validatedConfigDigest childConfig)
                            (childConfigDigest payload)
                            input
                    of
                        Left failure -> pure (Left (failureText "target frame" failure))
                        Right action -> action
      where
        input =
            HandoffBindingInput
                { requestedSpecDigest = validatedConfigSpecDigest childConfig
                , requestedPayloadKind = NarrowedProjectConfig
                , requestedPlanRevision = planDigestBindingDigestKernel binding
                , requestedParentFrame = parentFrameId
                , requestedChildFrame = child
                , requestedChildConfigDigest = validatedConfigDigest childConfig
                , requestedPhase = "execute"
                }

expectedChildContext ::
    Context.ContextPlacement ->
    Context.BinaryContext ->
    FilePath ->
    LiftContext ->
    Either Text Context.BinaryContext
expectedChildContext placement parent descriptor (LiftContext [layer]) = do
    expected <- case (placement, layer) of
        (Context.HostOrchestratorPlacement, ViaVM _) ->
            Right (Context.deriveVMContextWithProvider Context.IncusVMProvider parent root)
        (Context.HostOrchestratorPlacement, ViaLimaVM _) ->
            Right (Context.deriveVMContextWithProvider Context.LimaVMProvider parent root)
        (Context.HostOrchestratorPlacement, ViaWsl2VM _) ->
            Right (Context.deriveVMContextWithProvider Context.Wsl2VMProvider parent root)
        (Context.HostOrchestratorPlacement, ViaContainer _) ->
            Right (Context.deriveLinuxGpuContainerContext parent root)
        (Context.VMOrchestratorPlacement _, ViaContainer _) ->
            Right (Context.deriveContainerContext parent root)
        _ -> refusal "the selected lift is illegal for the parent placement"
    case (Context.validateTopology expected, Context.contextPlacement expected) of
        (Left failure, _) -> Left (failureText "binary context" failure)
        (_, Left failure) -> Left (failureText "binary context" failure)
        (Right (), Right _) -> Right expected
  where
    root = Text.pack descriptor
expectedChildContext _ _ _ _ = refusal "the selected lift is not exactly one layer"

validatePlanPrefixes ::
    ProjectPlan scope specDigest parentPlanId parentConfigId cfg ->
    ProjectPlan scope specDigest childPlanId childConfigId cfg ->
    Context.BinaryContext ->
    Context.ContextPlacement ->
    Either Text ()
validatePlanPrefixes parent targetPlan childContext placement = do
    require (parentFrames == targetFrames) "parent and target frame-label prefixes differ"
    require (map fst parentFrames == contextIds && map fst targetFrames == contextIds) "plan IDs differ from child context"
    require (parentEdges == contextEdges && targetEdges == contextEdges) "plan edges differ from child context"
    require (map edgePair parentDescents == contextEdges && map edgePair targetDescents == contextEdges) "plan descents differ from child ancestry"
    case (reverse parentDescents, reverse targetDescents) of
        ((_, _, parentLift) : parentAncestors, (_, _, targetLift) : targetAncestors) -> do
            require (map descentLift parentAncestors == map descentLift targetAncestors) "ancestor lifts differ before the selected child"
            selectedLiftMatches placement parentLift targetLift
        _ -> refusal "the selected child has no complete descent ancestry"
  where
    parentTopology = topologyKernel parent
    targetTopology = topologyKernel targetPlan
    contextIds = map Context.topologyFrameId (Context.topologyFrames childContext)
    contextEdges =
        [ (Context.topologyParentId frame, Context.topologyFrameId frame)
        | frame <- Context.topologyFrames childContext
        , not (Text.null (Context.topologyParentId frame))
        ]
    parentFrames = take (length contextIds) (NonEmpty.toList (topologyFrameOrderKernel parentTopology))
    targetFrames = take (length contextIds) (NonEmpty.toList (topologyFrameOrderKernel targetTopology))
    parentEdges = take (length contextEdges) (topologyParentEdgesKernel parentTopology)
    targetEdges = take (length contextEdges) (topologyParentEdgesKernel targetTopology)
    parentDescents = take (length contextEdges) (topologyDescentEdgesKernel parentTopology)
    targetDescents = take (length contextEdges) (topologyDescentEdgesKernel targetTopology)
    edgePair (from, to, _) = (from, to)
    descentLift (_, _, route) = route

selectedLiftMatches ::
    Context.ContextPlacement -> LiftContext -> LiftContext -> Either Text ()
selectedLiftMatches
    Context.HostOrchestratorPlacement
    (LiftContext [ViaContainer parent])
    (LiftContext [ViaContainer targetRoute]) = directContainerRebase parent targetRoute
selectedLiftMatches _ parent targetRoute =
    require (parent == targetRoute) "the selected VM or VM-container lift differs"

directContainerRebase :: ContainerLift -> ContainerLift -> Either Text ()
directContainerRebase parent targetContainer = do
    require (clImage parent == clImage targetContainer) "direct container image differs"
    require (clExtraArgs parent == clExtraArgs targetContainer) "direct container arguments differ"
    require (clRemoveAfter parent == clRemoveAfter targetContainer) "direct container remove policy differs"
    require (clConfigDelivery parent == clConfigDelivery targetContainer) "direct config delivery differs"
    require (length parentMounts == length targetMounts) "direct container mount count differs"
    require (filter (== dockerSocket) parentMounts == [dockerSocket] && filter (== dockerSocket) targetMounts == [dockerSocket]) "Docker socket mount differs"
    case [(old, new) | (old, new) <- zip parentMounts targetMounts, old /= new] of
        [(old, new)] -> do
            require (writable parentMounts == [old] && writable targetMounts == [new]) "direct writable mount is ambiguous"
            require (target old == target new) "direct durable target differs"
            require (target new /= "/var/run/docker.sock") "Docker socket source cannot be rebased"
            require (not (Text.null (source old))) "direct durable source is empty"
            require (source new == target new) "child-local durable source does not equal its target"
            require (canonical (source new) && canonical (target new)) "child-local durable path is not canonical POSIX"
        _ -> refusal "direct route must rebase exactly one mount source"
  where
    parentMounts = clMounts parent
    targetMounts = clMounts targetContainer
    dockerSocket = Mount "/var/run/docker.sock" "/var/run/docker.sock" False
    writable = filter (\mount -> mount /= dockerSocket && not (readOnly mount))
    canonical = canonicalProjectedRootKernel . Text.unpack

containerPayloadMatches :: LiftContext -> ByteString -> Either Text ()
containerPayloadMatches (LiftContext [ViaContainer container]) payload =
    case clConfigDelivery container of
        Just delivery ->
            require
                (TextEncoding.encodeUtf8 (cdPayload delivery) == payload)
                "container delivery differs from the canonical payload"
        Nothing -> refusal "container handoff has no canonical config delivery"
containerPayloadMatches _ _ = Right ()

withoutConfigDelivery :: LiftContext -> LiftContext
withoutConfigDelivery (LiftContext [ViaContainer container]) =
    LiftContext [ViaContainer container{clConfigDelivery = Nothing}]
withoutConfigDelivery route = route

require :: Bool -> Text -> Either Text ()
require True _ = Right ()
require False detail = refusal detail

refusal :: Text -> Either Text value
refusal detail = Left ("immediate target projection: " <> detail)

failureText :: Show failure => Text -> failure -> Text
failureText label failure =
    "immediate target projection: " <> label <> " refused: " <> Text.pack (show failure)
