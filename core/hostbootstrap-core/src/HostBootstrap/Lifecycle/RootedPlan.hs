{-# LANGUAGE GADTs #-}
{-# LANGUAGE NoMonoLocalBinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | The root-owned recursive plan catalog.

One root process recursively projects and admits every declared descendant
configuration and plan before any remote frame performs a lifecycle effect.
The catalog is the exact result of that recursion: it retains the root's own
finalized specification, invocation authority, plan, current frame, and
root-resident lifecycle context, plus one entry per admitted descent edge.

The value is inert.  It grants no journal, cursor, session, grant, signing,
process, or protected-store operation, and its entries are reachable only
through the rank-2 folds below — no entry, row, or nested lifecycle context
escapes as an independently constructible value.

The same owner renders the catalog's one bounded canonical manifest and
strictly compares an observed durable manifest with it.  Both are pure: this
module names no store, session, record, or compare-and-swap operation, so the
root entry that persists the manifest holds the only durable authority.
-}
module HostBootstrap.Lifecycle.RootedPlan
    ( RootedPlanCatalog
    , withRootedPlanCatalogKernel
    , withRootedPlanCatalogRootKernel
    , withRootedPlanCatalogEntriesKernel
    , withRootedPlanCatalogEntryKernel
    , withRootedPlanCatalogEdgeKernel
    , rootedPlanCatalogRecordIdentityKernel
    , rootedPlanCatalogManifestKernel
    , rootedPlanCatalogManifestMatchesKernel
    )
where

import Data.Bits (shiftR)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Authority.Kernel
    ( RootInvocationAuthority
    , rootAuthorityProjectName
    , rootAuthorityStoreIdentity
    )
import HostBootstrap.Config.Class (ProjectCfg)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Lifecycle.Context.Internal
    ( ValidatedLifecycleContext
    , withValidatedRootLifecycleContext
    )
import HostBootstrap.Lifecycle.Plan
    ( PlanDigestBinding
    , ProjectPlan
    , forwardKernel
    , planDigestBindingDigestKernel
    , plannedStepFrameIdKernel
    , plannedStepProjectedOperationKeysKernel
    , projectPlanProfileEpochKernel
    , projectPlanProfileNameKernel
    , projectPlanProfileProjectNameKernel
    , projectPlanProfileStoreIdentityKernel
    , renderSnapshotKernel
    , stablePlanSnapshotDigestKernel
    , stablePlanSnapshotSpecDigestKernel
    , topologyDescentFromKernel
    , topologyFrameOrderKernel
    , topologyKernel
    )
import HostBootstrap.Lift.Context (LiftContext)
import HostBootstrap.ProjectPlan.Construct.Internal (FinalizedProjectSpec)
import HostBootstrap.ProjectPlan.Frame
    ( CurrentFrame
    , currentFrameId
    , projectFrameId
    , validatedContextValue
    )
import HostBootstrap.ProjectPlan.Projection.Internal (withImmediateTargetKernel)
import HostBootstrap.Step (OperationKey, operationKeyText)

{- | The exact recursive catalog for one root plan and one invocation broker
generation.

The base carries the root's retained evidence; every extension carries one
admitted descent edge together with the complete target evidence a later
package or storeless executor needs.  The four indices are nominal, so a
catalog admitted for one scope, root plan, broker generation, or construction
cannot be relabelled as another with 'coerce'.
-}
data RootedPlanCatalog scope rootPlanId brokerGeneration catalogId where
    RootedPlanCatalogRoot ::
        (ProjectCfg cfg) =>
        FinalizedProjectSpec scope specDigest cfg ->
        RootInvocationAuthority scope brokerGeneration verb ->
        ProjectPlan scope specDigest rootPlanId rootConfigId cfg ->
        CurrentFrame scope rootPlanId rootFrame ->
        ValidatedLifecycleContext scope specDigest rootPlanId rootConfigId rootFrame ->
        RootedPlanCatalog scope rootPlanId brokerGeneration catalogId
    RootedPlanCatalogDescent ::
        (ProjectCfg cfg) =>
        RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
        ProjectPlan scope specDigest childPlanId childConfigId cfg ->
        PlanDigestBinding scope specDigest childPlanDigest childPlanId ->
        CurrentFrame scope childPlanId childFrame ->
        Text ->
        Text ->
        LiftContext ->
        LiftContext ->
        ByteString ->
        Text ->
        Text ->
        [OperationKey] ->
        RootedPlanCatalog scope rootPlanId brokerGeneration catalogId

type role RootedPlanCatalog nominal nominal nominal nominal

{- | Construct the catalog for one root frame.

The supplied current frame must be the lifecycle context's own root-resident
frame and its admitted context's endpoint, and the invocation authority must
name the same installed project and durable store identity the root plan
retains.  Only then does the shared immediate-target kernel project each
declared descent in turn, each level's admitted target becoming the next
level's parent, until a frame declares no further descent.  The recursion is
bounded by the root topology's own frame count, and no effect runs before the
continuation receives the completed catalog.
-}
withRootedPlanCatalogKernel ::
    (ProjectCfg cfg) =>
    FinalizedProjectSpec scope specDigest cfg ->
    RootInvocationAuthority scope brokerGeneration verb ->
    ProjectPlan scope specDigest rootPlanId rootConfigId cfg ->
    CurrentFrame scope rootPlanId rootFrame ->
    ValidatedLifecycleContext scope specDigest rootPlanId rootConfigId rootFrame ->
    ( forall catalogId.
      RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withRootedPlanCatalogKernel finalized authority rootPlan rootCurrent lifecycle use =
    case withValidatedRootLifecycleContext lifecycle borrow of
        Left failure -> pure (Left (failureText "lifecycle context" failure))
        Right action -> action
  where
    borrow _ _ retainedCurrent projectFrame validated =
        admitRoot retainedCurrent (projectFrameId projectFrame) (validatedContextValue validated)

    admitRoot retainedCurrent projectId rootContext
        | rootId /= currentFrameId retainedCurrent || rootId /= projectId =
            pure (refusal "root frame evidence differs")
        | rootId /= Context.currentFrame rootContext =
            pure (refusal "root frame evidence differs from its admitted context")
        | rootAuthorityProjectName authority /= projectPlanProfileProjectNameKernel rootPlan =
            pure (refusal "root invocation authority names another installed project")
        | rootAuthorityStoreIdentity authority /= projectPlanProfileStoreIdentityKernel rootPlan =
            pure (refusal "root invocation authority names another durable store identity")
        | otherwise =
            descendRootedPlanCatalogKernel
                finalized
                (length (NonEmpty.toList (topologyFrameOrderKernel (topologyKernel rootPlan))))
                (RootedPlanCatalogRoot finalized authority rootPlan rootCurrent lifecycle)
                rootPlan
                rootCurrent
                rootContext
                use
      where
        rootId = currentFrameId rootCurrent

{- | Extend the catalog along the single declared descent of one admitted
frame, then continue from the admitted target.
-}
descendRootedPlanCatalogKernel ::
    (ProjectCfg cfg) =>
    FinalizedProjectSpec scope specDigest cfg ->
    Int ->
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId frame ->
    Context.BinaryContext ->
    (RootedPlanCatalog scope rootPlanId brokerGeneration catalogId -> IO (Either Text ())) ->
    IO (Either Text ())
descendRootedPlanCatalogKernel finalized budget catalog plan current context use =
    case topologyDescentFromKernel (topologyKernel plan) frameName of
        Nothing -> use catalog
        Just _
            | budget <= 0 ->
                pure (refusal "the recursive catalog exceeds the root topology depth")
            | otherwise ->
                withImmediateTargetKernel finalized plan current context extend
  where
    frameName = currentFrameId current

    extend targetPlan binding targetCurrent childContext parentFrame childFrame raw route payload configDigest payloadDigest _input =
        descendRootedPlanCatalogKernel
            finalized
            (budget - 1)
            ( RootedPlanCatalogDescent
                catalog
                targetPlan
                binding
                targetCurrent
                parentFrame
                childFrame
                raw
                route
                payload
                configDigest
                payloadDigest
                (projectedNodeKeys plan parentFrame)
            )
            targetPlan
            targetCurrent
            childContext
            use

{- | The exact plan-owned operation keys one frame's steps project onto their
declared descent.
-}
projectedNodeKeys ::
    ProjectPlan scope specDigest planId configId cfg -> Text -> [OperationKey]
projectedNodeKeys plan frameName =
    concat
        [ plannedStepProjectedOperationKeysKernel step
        | step <- NonEmpty.toList (forwardKernel plan)
        , plannedStepFrameIdKernel step == frameName
        ]

-- | Borrow the root evidence the catalog was constructed from.
withRootedPlanCatalogRootKernel ::
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    ( forall specDigest rootConfigId rootFrame verb cfg.
      (ProjectCfg cfg) =>
      FinalizedProjectSpec scope specDigest cfg ->
      RootInvocationAuthority scope brokerGeneration verb ->
      ProjectPlan scope specDigest rootPlanId rootConfigId cfg ->
      CurrentFrame scope rootPlanId rootFrame ->
      ValidatedLifecycleContext scope specDigest rootPlanId rootConfigId rootFrame ->
      result
    ) ->
    result
withRootedPlanCatalogRootKernel catalog use =
    case catalog of
        RootedPlanCatalogRoot finalized authority plan current lifecycle ->
            use finalized authority plan current lifecycle
        RootedPlanCatalogDescent ancestors _ _ _ _ _ _ _ _ _ _ _ ->
            withRootedPlanCatalogRootKernel ancestors use

{- | Fold every admitted descent entry in canonical root-first order.

Each entry jointly exposes the exact target plan, its digest binding and
current frame, the parent/child edge, the raw and stripped plan-owned routes,
the canonical child configuration bytes, the configuration and payload
digests, and the frame's projected node keys.
-}
withRootedPlanCatalogEntriesKernel ::
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    ( forall specDigest childPlanDigest childPlanId childConfigId childFrame cfg.
      (ProjectCfg cfg) =>
      ProjectPlan scope specDigest childPlanId childConfigId cfg ->
      PlanDigestBinding scope specDigest childPlanDigest childPlanId ->
      CurrentFrame scope childPlanId childFrame ->
      Text ->
      Text ->
      LiftContext ->
      LiftContext ->
      ByteString ->
      Text ->
      Text ->
      [OperationKey] ->
      result
    ) ->
    [result]
withRootedPlanCatalogEntriesKernel catalog use = collect catalog []
  where
    collect (RootedPlanCatalogRoot _ _ _ _ _) collected = collected
    collect (RootedPlanCatalogDescent ancestors plan binding current parent child raw route payload configDigest payloadDigest keys) collected =
        collect
            ancestors
            (use plan binding current parent child raw route payload configDigest payloadDigest keys : collected)

{- | Select the single entry whose admitted child frame is the requested one.

Selection is a fold over the catalog itself; there is no row, index, or entry
value a caller can hold independently of it.
-}
withRootedPlanCatalogEntryKernel ::
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    Text ->
    ( forall specDigest childPlanDigest childPlanId childConfigId childFrame cfg.
      (ProjectCfg cfg) =>
      ProjectPlan scope specDigest childPlanId childConfigId cfg ->
      PlanDigestBinding scope specDigest childPlanDigest childPlanId ->
      CurrentFrame scope childPlanId childFrame ->
      Text ->
      Text ->
      LiftContext ->
      LiftContext ->
      ByteString ->
      Text ->
      Text ->
      [OperationKey] ->
      result
    ) ->
    Maybe result
withRootedPlanCatalogEntryKernel catalog requested use = select catalog
  where
    select (RootedPlanCatalogRoot _ _ _ _ _) = Nothing
    select (RootedPlanCatalogDescent ancestors plan binding current parent child raw route payload configDigest payloadDigest keys)
        | child == requested =
            Just (use plan binding current parent child raw route payload configDigest payloadDigest keys)
        | otherwise = select ancestors

{- | Select the one admitted descent edge a storeless forward package may be
produced for, together with the parent level's own retained evidence.

Selection is by exact parent and child frame.  A child frame no entry names is
missing; a child frame more than one entry names is a duplicate; a child frame
whose single admitted entry was reached from another parent is a sibling of the
requested edge rather than the edge itself.  The selected entry is then
rechecked against the parent level's own retained plan and current frame: the
retained parent frame must be that level's own current frame, the parent plan
must declare exactly the retained raw route as the single descent out of that
frame, and the frame's plan-owned projected node keys must be the ones the
entry retains.  Coordinates or keys that came from an independent projection
rather than from this catalog's own recursion therefore refuse here, before any
continuation runs.

The fold exposes no entry, row, or nested lifecycle context as an
independently constructible value.  The parent level contributes only its own
frame identity: the parent plan is what the rechecks are made against, never
what the continuation receives.
-}
withRootedPlanCatalogEdgeKernel ::
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    Text ->
    Text ->
    ( forall parentPlanId parentFrame specDigest childPlanDigest childPlanId childConfigId childFrame cfg.
      (ProjectCfg cfg) =>
      CurrentFrame scope parentPlanId parentFrame ->
      ProjectPlan scope specDigest childPlanId childConfigId cfg ->
      PlanDigestBinding scope specDigest childPlanDigest childPlanId ->
      CurrentFrame scope childPlanId childFrame ->
      LiftContext ->
      LiftContext ->
      ByteString ->
      Text ->
      Text ->
      [OperationKey] ->
      result
    ) ->
    Either Text result
withRootedPlanCatalogEdgeKernel catalog requestedParent requestedChild use =
    case collect catalog [] of
        [] -> refusal "no admitted descent edge names the requested child frame"
        [selected] -> selected
        _ -> refusal "more than one admitted descent edge names the requested child frame"
  where
    collect (RootedPlanCatalogRoot _ _ _ _ _) collected = collected
    collect (RootedPlanCatalogDescent ancestors plan binding current parent child raw route payload configDigest payloadDigest keys) collected
        | child /= requestedChild = collect ancestors collected
        | otherwise =
            collect
                ancestors
                (admit ancestors plan binding current parent child raw route payload configDigest payloadDigest keys : collected)

    admit ancestors plan binding current parent child raw route payload configDigest payloadDigest keys
        | parent /= requestedParent = refusal "the admitted edge names another parent frame"
        | otherwise = withRootedPlanCatalogFrameKernel ancestors joinParent
      where
        joinParent parentPlan parentCurrent
            | currentFrameId parentCurrent /= parent =
                refusal "the admitted parent frame is not its own retained current frame"
            | topologyDescentFromKernel (topologyKernel parentPlan) parent /= Just (child, raw) =
                refusal "the parent plan declares no such descent out of the admitted parent frame"
            | projectedNodeKeys parentPlan parent /= keys =
                refusal "the admitted projected node keys are not the parent plan's own"
            | otherwise =
                Right
                    (use parentCurrent plan binding current raw route payload configDigest payloadDigest keys)

{- | Borrow the plan and current frame one catalog level itself stands on.

The root level stands on the root plan and root frame; every descent level
stands on its own admitted target, which is exactly the parent evidence of the
next level down.
-}
withRootedPlanCatalogFrameKernel ::
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    ( forall specDigest planId configId frame cfg.
      (ProjectCfg cfg) =>
      ProjectPlan scope specDigest planId configId cfg ->
      CurrentFrame scope planId frame ->
      result
    ) ->
    result
withRootedPlanCatalogFrameKernel catalog use =
    case catalog of
        RootedPlanCatalogRoot _ _ plan current _ -> use plan current
        RootedPlanCatalogDescent _ plan _ current _ _ _ _ _ _ _ _ -> use plan current

{- | The durable record identity one catalog is keyed by.

The identity is a path of the root plan's own installed project, stable
profile, and broker epoch, so a second invocation lineage never addresses the
record a live one owns.  A stable profile is itself a namespaced identity —
a Harness profile names its run — so the path is returned unencoded and the
root entry that owns the store encodes it into a record name.
-}
rootedPlanCatalogRecordIdentityKernel ::
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId -> Text
rootedPlanCatalogRecordIdentityKernel catalog =
    withRootedPlanCatalogRootKernel catalog identity
  where
    identity _finalized _authority plan _current _lifecycle =
        "catalog/"
            <> projectPlanProfileProjectNameKernel plan
            <> "/"
            <> projectPlanProfileNameKernel plan
            <> "/"
            <> Text.pack (show (projectPlanProfileEpochKernel plan))

{- | Render the one bounded canonical manifest for a complete catalog.

Every variable-width value is length-framed and every list carries an explicit
count, so the bytes are canonical rather than delimiter-joined.  The root
header frames the installed project, stable profile, broker epoch, durable
store identity, specification digest, root plan digest, and root frame; each
admitted descent then frames its exact parent/child edge, target plan digest,
configuration and payload digests, and the parent frame's plan-owned projected
node keys, in the catalog's own root-first order.  A raw configuration payload
is never present.  Both ceilings are refusals rather than truncations.
-}
rootedPlanCatalogManifestKernel ::
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    Either Text ByteString
rootedPlanCatalogManifestKernel catalog
    | entryCount > rootedPlanCatalogEntryCeiling =
        refusal "the recursive catalog manifest exceeds its entry ceiling"
    | ByteString.length rendered > rootedPlanCatalogManifestCeiling =
        refusal "the recursive catalog manifest exceeds its byte ceiling"
    | otherwise = Right rendered
  where
    entries = withRootedPlanCatalogEntriesKernel catalog manifestEntry
    entryCount = length entries
    rendered =
        ByteString.concat
            ( withRootedPlanCatalogRootKernel catalog manifestRoot
                : manifestWord (fromIntegral entryCount)
                : entries
            )

    manifestRoot _finalized _authority plan current _lifecycle =
        ByteString.concat
            [ manifestFrame "hostbootstrap/rooted-plan-catalog"
            , manifestWord 1
            , manifestText (projectPlanProfileProjectNameKernel plan)
            , manifestText (projectPlanProfileNameKernel plan)
            , manifestWord (projectPlanProfileEpochKernel plan)
            , manifestText (projectPlanProfileStoreIdentityKernel plan)
            , manifestText (stablePlanSnapshotSpecDigestKernel snapshot)
            , manifestText (stablePlanSnapshotDigestKernel snapshot)
            , manifestText (currentFrameId current)
            ]
      where
        snapshot = renderSnapshotKernel plan

    manifestEntry plan binding _current parent child _raw _route _payload configDigest payloadDigest keys =
        ByteString.concat
            [ manifestText parent
            , manifestText child
            , manifestText (planDigestBindingDigestKernel binding)
            , manifestText (stablePlanSnapshotDigestKernel (renderSnapshotKernel plan))
            , manifestText configDigest
            , manifestText payloadDigest
            , manifestWord (fromIntegral (length keys))
            , ByteString.concat
                [manifestText (Text.pack (operationKeyText key)) | key <- keys]
            ]

{- | Strictly compare an observed durable manifest with this catalog's own.

Equality is over the complete canonical bytes, so a differing root plan
digest, specification digest, broker epoch, entry count, entry order, edge
coordinate, digest, or projected node key is a refusal rather than a partial
match.
-}
rootedPlanCatalogManifestMatchesKernel ::
    RootedPlanCatalog scope rootPlanId brokerGeneration catalogId ->
    ByteString ->
    Either Text ()
rootedPlanCatalogManifestMatchesKernel catalog observed =
    case rootedPlanCatalogManifestKernel catalog of
        Left failure -> Left failure
        Right expected
            | expected == observed -> Right ()
            | otherwise ->
                refusal "the durable recursive catalog manifest differs from the admitted catalog"

-- | The most admitted descent edges one durable manifest may carry.
rootedPlanCatalogEntryCeiling :: Int
rootedPlanCatalogEntryCeiling = 64

-- | The most canonical bytes one durable manifest may occupy.
rootedPlanCatalogManifestCeiling :: Int
rootedPlanCatalogManifestCeiling = 65536

manifestFrame :: ByteString -> ByteString
manifestFrame value =
    manifestWord (fromIntegral (ByteString.length value)) <> value

manifestText :: Text -> ByteString
manifestText = manifestFrame . TextEncoding.encodeUtf8

manifestWord :: Word64 -> ByteString
manifestWord value =
    ByteString.pack
        [fromIntegral (value `shiftR` offset) | offset <- [56, 48, 40, 32, 24, 16, 8, 0]]

refusal :: Text -> Either Text value
refusal detail = Left ("rooted plan catalog: " <> detail)

failureText :: Show failure => Text -> failure -> Text
failureText label failure =
    "rooted plan catalog: " <> label <> " refused: " <> Text.pack (show failure)
