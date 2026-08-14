{-# LANGUAGE GADTs #-}
{-# LANGUAGE NoMonoLocalBinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Exact, inert evidence for one forward lifecycle handoff.

Descriptor, context, configuration, and target-plan validation belong to the
shared immediate-target projection kernel.  This module owns only the exact
lifecycle-context join, the two sealed packages, and their fixed-unit
eliminators.

The immediate 'PlannedForwardHandoff' is the inert single-edge foundation: one
parent frame projects its own declared descent and retains the lifecycle
context it was admitted under.  'CatalogForwardHandoff' is the storeless
package a recursive descent edge authorizes: it is produced only from an edge
the root-owned plan catalog already admitted, retains no lifecycle context, and
carries no store, catalog row, process, or effect authority.
-}
module HostBootstrap.ProjectPlan.Handoff.Internal
    ( PlannedForwardHandoff
    , withPlannedForwardHandoffKernel
    , withPlannedForwardProcessInputsKernel
    , CatalogForwardHandoff
    , withCatalogForwardHandoffKernel
    , withCatalogForwardProcessInputsKernel
    )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Config.Class (ProjectCfg (cfgContext))
import HostBootstrap.Config.Schema
    ( validatedConfigDigest
    , validatedConfigSpecDigest
    , validatedConfigValue
    )
import qualified HostBootstrap.Context as Context
import HostBootstrap.Handoff
    ( HandoffBindingInput (..)
    , HandoffPayloadKind (NarrowedProjectConfig)
    , childConfigDigest
    )
import HostBootstrap.Lifecycle.Context.Internal
    ( LifecycleContextError (LifecycleContextRootFrameRequired)
    , ValidatedLifecycleContext
    , withValidatedNestedLifecycleContext
    , withValidatedRootLifecycleContext
    )
import HostBootstrap.Lifecycle.Plan
    ( PlanDigestBinding
    , ProjectPlan
    , planDigestBindingDigestKernel
    , projectPlanValidatedConfigKernel
    , renderSnapshotKernel
    , stablePlanSnapshotDigestKernel
    )
import HostBootstrap.Lifecycle.RootedPlan
    ( RootedPlanCatalog
    , withRootedPlanCatalogEdgeKernel
    )
import HostBootstrap.Lift.Context (LiftContext (..))
import HostBootstrap.ProjectPlan.Construct.Internal (FinalizedProjectSpec)
import HostBootstrap.ProjectPlan.Frame
    ( CurrentFrame
    , currentFrameId
    , projectFrameId
    , validatedContextValue
    )
import HostBootstrap.ProjectPlan.Projection.Internal (withImmediateTargetKernel)
import HostBootstrap.Step (OperationKey)

data PlannedForwardHandoff
    scope
    specDigest
    parentPlanId
    parentConfigId
    parentFrame
    childPlanDigest
    childConfigId
    childFrame where
    PlannedForwardHandoff ::
        ProjectPlan scope specDigest parentPlanId parentConfigId cfg ->
        CurrentFrame scope parentPlanId parentFrame ->
        ValidatedLifecycleContext
            scope specDigest parentPlanId parentConfigId parentFrame ->
        ProjectPlan scope specDigest childPlanId childConfigId cfg ->
        PlanDigestBinding scope specDigest childPlanDigest childPlanId ->
        CurrentFrame scope childPlanId childFrame ->
        LiftContext ->
        LiftContext ->
        HandoffBindingInput ->
        ByteString ->
        PlannedForwardHandoff
            scope
            specDigest
            parentPlanId
            parentConfigId
            parentFrame
            childPlanDigest
            childConfigId
            childFrame

type role PlannedForwardHandoff nominal nominal nominal nominal nominal nominal nominal nominal

withPlannedForwardHandoffKernel ::
    (ProjectCfg cfg) =>
    FinalizedProjectSpec scope specDigest cfg ->
    ProjectPlan scope specDigest parentPlanId parentConfigId cfg ->
    CurrentFrame scope parentPlanId parentFrame ->
    ValidatedLifecycleContext
        scope specDigest parentPlanId parentConfigId parentFrame ->
    ( forall childPlanDigest childConfigId childFrame.
      PlannedForwardHandoff
        scope
        specDigest
        parentPlanId
        parentConfigId
        parentFrame
        childPlanDigest
        childConfigId
        childFrame ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withPlannedForwardHandoffKernel finalized parent suppliedCurrent lifecycle use =
    case withValidatedRootLifecycleContext lifecycle borrow of
        Right action -> flatten action
        Left (LifecycleContextRootFrameRequired _) ->
            either (pure . Left . failureText "lifecycle context") flatten
                (withValidatedNestedLifecycleContext lifecycle borrow)
        Left failure -> pure (Left (failureText "lifecycle context" failure))
  where
    borrow _ _ retainedCurrent projectFrame validated =
        admitLifecycle retainedCurrent (projectFrameId projectFrame) (validatedContextValue validated)

    admitLifecycle retainedCurrent projectId parentContext
        | suppliedId /= retainedId || suppliedId /= projectId =
            pure (refusal "parent frame evidence differs")
        | otherwise =
            withImmediateTargetKernel finalized parent suppliedCurrent parentContext sealPlanned
      where
        suppliedId = currentFrameId suppliedCurrent
        retainedId = currentFrameId retainedCurrent

    sealPlanned targetPlan binding targetCurrent _child _parentFrame _childFrame raw route payload _configDigest _payloadDigest input =
        runPlannedForward
            ( PlannedForwardHandoff
                parent
                suppliedCurrent
                lifecycle
                targetPlan
                binding
                targetCurrent
                raw
                route
                input
                payload
            )
            use

    flatten action =
        action >>= either (\failure -> failure `seq` pure (Left failure)) (\() -> pure (Right ()))

withPlannedForwardProcessInputsKernel ::
    PlannedForwardHandoff
        scope
        specDigest
        parentPlanId
        parentConfigId
        parentFrame
        childPlanDigest
        childConfigId
        childFrame ->
    (LiftContext -> HandoffBindingInput -> ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
withPlannedForwardProcessInputsKernel planned use = runPlannedForward planned expose
  where
    expose (PlannedForwardHandoff _ _ _ _ _ _ _ route input payload) = use route input payload

runPlannedForward ::
    PlannedForwardHandoff a b c d e f g h ->
    (PlannedForwardHandoff a b c d e f g h -> result) ->
    result
runPlannedForward planned@(PlannedForwardHandoff parent current lifecycle targetPlan binding child raw route input payload) use =
    parent `seq` current `seq` lifecycle `seq` targetPlan `seq` binding `seq`
        child `seq` raw `seq` route `seq` input `seq` payload `seq` use planned

refusal :: Text -> Either Text value
refusal detail = Left ("planned forward handoff: " <> detail)

failureText :: Show failure => Text -> failure -> Text
failureText label failure =
    "planned forward handoff: " <> label <> " refused: " <> Text.pack (show failure)

{- | The storeless forward package one catalog-admitted descent edge
authorizes.

The eight indices are nominal, so a package produced for one scope, root plan,
broker generation, catalog, parent frame, child plan digest, child
configuration, or child frame cannot be relabelled as another with 'coerce'.
The parent plan, its configuration, and the specification index stay hidden
inside the constructor: this package names the child a parent frame descends
into, not the parent's own plan identity.

The value retains no lifecycle context, protected store, catalog row, journal,
cursor, session, grant, signing, or process authority, and the one eliminator
below exposes only the stripped route, binding input, and canonical payload
under a fixed unit result.
-}
data CatalogForwardHandoff
    scope
    rootPlanId
    brokerGeneration
    catalogId
    parentFrame
    childPlanDigest
    childConfigId
    childFrame where
    CatalogForwardHandoff ::
        (ProjectCfg cfg) =>
        CurrentFrame scope parentPlanId parentFrame ->
        ProjectPlan scope specDigest childPlanId childConfigId cfg ->
        PlanDigestBinding scope specDigest childPlanDigest childPlanId ->
        CurrentFrame scope childPlanId childFrame ->
        Text ->
        Text ->
        LiftContext ->
        LiftContext ->
        HandoffBindingInput ->
        ByteString ->
        Text ->
        Text ->
        [OperationKey] ->
        CatalogForwardHandoff
            scope
            rootPlanId
            brokerGeneration
            catalogId
            parentFrame
            childPlanDigest
            childConfigId
            childFrame

type role CatalogForwardHandoff nominal nominal nominal nominal nominal nominal nominal nominal

{- | Produce the exact forward package for one admitted recursive descent edge.

The catalog itself selects the edge, refusing a missing, duplicated, or
sibling child frame and refusing coordinates, routes, or projected node keys
that were not produced by its own recursion.  This kernel then rechecks the
selected entry against the evidence the entry retains rather than against
anything a caller supplied: the admitted child frame must be the target plan's
own current frame and its validated configuration's endpoint, the retained
child plan digest must be the digest that plan still renders and the digest its
binding carries, and the retained configuration and payload digests must equal
one another and the digest the canonical payload still hashes to.  Both routes
must remain exactly one lift layer.

Only then is the binding input rebuilt from the admitted evidence and the
package sealed.  Every check finishes before the rank-2 continuation runs, so a
refusal creates no package, session, or process.
-}
withCatalogForwardHandoffKernel ::
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    Text ->
    Text ->
    ( forall parentFrame childPlanDigest childConfigId childFrame.
      CatalogForwardHandoff
        scope
        rootPlanId
        brokerGeneration
        catalogId
        parentFrame
        childPlanDigest
        childConfigId
        childFrame ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withCatalogForwardHandoffKernel catalog requestedParent requestedChild use =
    case withRootedPlanCatalogEdgeKernel catalog requestedParent requestedChild sealCatalog of
        Left failure -> pure (Left (catalogFailure failure))
        Right action -> action
  where
    sealCatalog parentCurrent childPlan binding childCurrent raw route payload configDigest payloadDigest keys
        | currentFrameId childCurrent /= requestedChild =
            pure (catalogRefusal "the admitted child frame differs from its own retained current frame")
        | Context.currentFrame (cfgContext (validatedConfigValue childConfig)) /= requestedChild =
            pure (catalogRefusal "the admitted child configuration does not end at the admitted child frame")
        | validatedConfigDigest childConfig /= configDigest =
            pure (catalogRefusal "the admitted child configuration digest differs from the target plan's own")
        | configDigest /= payloadDigest =
            pure (catalogRefusal "the admitted configuration and payload digests differ")
        | childConfigDigest payload /= payloadDigest =
            pure (catalogRefusal "the admitted canonical payload no longer hashes to its retained digest")
        | planDigestBindingDigestKernel binding /= renderedChildPlanDigest =
            pure (catalogRefusal "the admitted child plan digest differs from the target plan's own")
        | not (oneLayer raw) || not (oneLayer route) =
            pure (catalogRefusal "the admitted route is not exactly one lift layer")
        | otherwise =
            runCatalogForward
                ( CatalogForwardHandoff
                    parentCurrent
                    childPlan
                    binding
                    childCurrent
                    requestedParent
                    requestedChild
                    raw
                    route
                    input
                    payload
                    configDigest
                    payloadDigest
                    keys
                )
                use
      where
        childConfig = projectPlanValidatedConfigKernel childPlan
        renderedChildPlanDigest =
            stablePlanSnapshotDigestKernel (renderSnapshotKernel childPlan)
        input =
            HandoffBindingInput
                { requestedSpecDigest = validatedConfigSpecDigest childConfig
                , requestedPayloadKind = NarrowedProjectConfig
                , requestedPlanRevision = planDigestBindingDigestKernel binding
                , requestedParentFrame = requestedParent
                , requestedChildFrame = requestedChild
                , requestedChildConfigDigest = configDigest
                , requestedPhase = "execute"
                }

{- | Borrow only the stripped route, binding input, and canonical payload the
package retains.

No plan, digest binding, current frame, catalog, or projected node key escapes
through this fold, and the result is fixed rather than caller-selected.
-}
withCatalogForwardProcessInputsKernel ::
    CatalogForwardHandoff
        scope
        rootPlanId
        brokerGeneration
        catalogId
        parentFrame
        childPlanDigest
        childConfigId
        childFrame ->
    (LiftContext -> HandoffBindingInput -> ByteString -> IO (Either Text ())) ->
    IO (Either Text ())
withCatalogForwardProcessInputsKernel package use = runCatalogForward package expose
  where
    expose (CatalogForwardHandoff _ _ _ _ _ _ _ route input payload _ _ _) =
        use route input payload

runCatalogForward ::
    CatalogForwardHandoff a b c d e f g h ->
    (CatalogForwardHandoff a b c d e f g h -> result) ->
    result
runCatalogForward package@(CatalogForwardHandoff parentCurrent childPlan binding childCurrent parent child raw route input payload configDigest payloadDigest keys) use =
    parentCurrent `seq` childPlan `seq` binding `seq` childCurrent `seq` parent `seq`
        child `seq` raw `seq` route `seq` input `seq` payload `seq`
            configDigest `seq` payloadDigest `seq` keys `seq` use package

oneLayer :: LiftContext -> Bool
oneLayer (LiftContext [_]) = True
oneLayer _ = False

catalogRefusal :: Text -> Either Text value
catalogRefusal detail = Left ("catalog forward handoff: " <> detail)

catalogFailure :: Text -> Text
catalogFailure detail = "catalog forward handoff: " <> detail
