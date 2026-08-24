{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | The verb-indexed reverse projection and its teardown forest
(the recursive-lifecycle-command phase, @development_plan_standards.md@ § Y).

`project down` and `project destroy` are not two hand-written cleanup routines.
They are two **projections of the same validated plan**, and this module is
where that is made structural:

* 'TeardownPlan' is indexed by the exact admitted plan, current frame, and verb,
  so neither another plan's frame nor a @Down@ projection can be substituted for
  a @Destroy@ projection. Its nodes come only from the public project-plan
  projections and retain the same stable step and operation identities as the
  forward plan. The two verbs differ in exactly one place — a provider frame is
  *stopped* by @down@ and *deleted* by @destroy@ — and in neither does a step
  whose reverse policy is @PreserveOnReverse@ appear at all.
* The kind cluster is deleted by **both** verbs, because kind has no reliable
  stop/restart contract. Its removal set is empty, so no filesystem path is
  removed with it.
* 'openTeardownForest' is the **sole** initial producer of a forest. It consumes
  only the already-bound projection; there is no second plan or frame argument
  that could disagree with it. The forest and every authority, cursor, successor,
  completion, and 'SubtreeSettled' value retain that projection's nominal
  frame index. 'DestroySettled' deliberately drops the frame only after the
  exact plan/current-frame pair proves that subtree is the unique root.

The forest itself enforces child-first recursion. A frame's own teardown step is
not offered until every deeper frame's node has settled, so a parent is never
torn down out from under a child that still needs it. For @destroy@, a provider
node additionally offers a **pre-descent reachability** step first: after a
`down` the provider is stopped, and its retained children cannot be reached
until it is made reachable again. Only that step's success exposes the children,
and only their settlement exposes the ordinary provider stop/delete step.

Failure is constructive. Every attempt returns a successor forest, including on
failure; a failed node keeps its parent blocked while unrelated siblings stay
schedulable; and a forest containing a failure never completes. Only a
**completed** forest can enter 'verifySubtreeSettled'. Only a root-frame
@VerbDestroy@ subtree can then enter 'verifyDestroySettled', the sole producer
of 'DestroySettled' — the proof
@HostBootstrap.Lifecycle.Mode.destroySettledClosure@ requires before Production
mode may be released.

A foreign or refused observation is not a failure: § Y classifies compatible
unowned state as a `ForeignResult` and a policy decision as a `SafetyRefusal`,
and neither is torn down. Both settle their node — the run never owned the
object — and both are recorded on the forest so the report can name them.
-}
module HostBootstrap.Teardown (
    -- * The reverse projection
    TeardownAction (..),
    TeardownPlan,
    teardownPlan,
    failedUpTeardownPlanKernel,
    teardownPlanVerbName,
    teardownPlanFrameId,

    -- * The forest
    TeardownForest,
    openTeardownForest,
    teardownForestOutstanding,
    teardownForestFailures,
    teardownForestForeign,

    -- * Scheduling
    TeardownProgress,
    nextTeardownWork,
    eliminateTeardownProgress,
    CompletedTeardownForest,
    completedForestTerminalObservations,
    TeardownAuthorizationPoint,
    PreDescentStep,
    preDescentStepKey,
    preDescentStepFrame,
    SettledChildren,
    settledChildrenKeys,
    TeardownWork,
    LocalWork,
    localWorkAction,
    localWorkKey,
    localWorkOperationKey,
    localWorkPolicy,
    localWorkRun,
    DescentWork,
    descentWorkParentFrame,
    descentWorkChildFrame,
    withDescentWorkSubtree,
    eliminateTeardownWork,
    withTeardownAuthorization,

    -- * Attempting one step
    TeardownOutcome (..),
    renderTeardownObservations,
    teardownObservationsFromWire,
    attemptPreDescentStep,
    attemptLocalWork,
    settleDescentWork,
    failDescentWork,
    driveTeardownForest,

    -- * Settlement
    SubtreeSettled,
    subtreeSettledPlanDigest,
    subtreeSettledOpeningFrame,
    subtreeSettledVerbName,
    subtreeSettledTerminalObservations,
    subtreeSettledReleasedOperationKeys,
    verifySubtreeSettled,
    validateRootSubtreeSettled,
    DestroySettled,
    destroySettledPlanDigest,
    destroySettledTerminalObservations,
    destroySettledReleasedOperationKeys,
    verifyDestroySettled,
    settledDestroyEvidence,

    -- * Failures
    TeardownError (..),
    teardownErrorMessage,
) where

import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.List (nub)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Authority (
    ProjectVerb (..),
    VerbDestroy,
    VerbUp,
    projectVerbName,
 )
import HostBootstrap.Handoff (HandoffError, handoffErrorMessage, lifecycleObservationsFromWire, renderLifecycleObservations)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.ProjectPlan (
    OperationKey,
    PlannedStep,
    ProjectPlan,
    forward,
    operationKeyText,
    plannedStepFrameId,
    plannedStepIdentity,
    plannedStepOperationKey,
    plannedStepProjectedOperationKeys,
    plannedStepReversePolicy,
    plannedStepReverseRun,
    renderSnapshot,
    stablePlanSnapshotDigest,
    topology,
    topologyFrameOrder,
    topologyParentEdges,
 )
import HostBootstrap.ProjectPlan.Frame (CurrentFrame, currentFrameId)
import HostBootstrap.Step (
    CoreStepId (DeployKindId, DeployVMId),
    ReversePolicy (..),
    StepIdentity (..),
    TeardownAction (..),
    TeardownOutcome (..),
 )

-- ---------------------------------------------------------------------------
-- The reverse projection

{- | One node of the reverse projection, before a forest exists.

'reverseRun' is the effect the plan node itself declared with
'HostBootstrap.Step.reversedBy' — the step that acquired a resource is the step
that releases it. 'Nothing' means the node declared none: either the core
adapter owns it ('CoreManagedReverse') or it acquired nothing this frame must
release.
-}
data ReverseStep = ReverseStep
    { _reverseIdentity :: StepIdentity
    , reverseOperationKey :: OperationKey
    , reverseFrame :: Text
    , reversePlacement :: ReversePlacement
    , reverseAction :: TeardownAction
    , reversePolicy :: ReversePolicy
    , reverseRun :: Maybe (HostConfig -> TeardownAction -> IO TeardownOutcome)
    }

{- | The plan-derived relation between one reverse node and the frame that
opened this projection. Every descendant node names the opening frame's exact
immediate child, even when an intervening topology level contributes no
removable node to the forest.
-}
data ReversePlacement
    = ReverseLocal Text
    | ReverseDescent Text Text

reverseKey :: ReverseStep -> Text
reverseKey = Text.pack . operationKeyText . reverseOperationKey

{- | The pure, verb-indexed reverse projection of one validated plan.

Derived only from a 'ProjectPlan' and its already-admitted 'CurrentFrame', so
the identities it names are exactly the plan's own step identities and
operation keys — the structural property § W requires of the forward and
reverse projections.
-}
data TeardownPlan scope planId frame verb
    = TeardownPlan (ProjectVerb verb) Bool Text Text [Text] [[ReverseStep]]

type role TeardownPlan nominal nominal nominal nominal

teardownPlanVerbName :: TeardownPlan scope planId frame verb -> Text
teardownPlanVerbName (TeardownPlan verb _ _ _ _ _) = projectVerbName verb

-- | The exact semantic frame from which this reverse projection begins.
teardownPlanFrameId :: TeardownPlan scope planId frame verb -> Text
teardownPlanFrameId (TeardownPlan _ _ _ frame _ _) = frame

projectedOperationKeys :: TeardownPlan scope planId frame verb -> [OperationKey]
projectedOperationKeys (TeardownPlan _ _ _ _ _ levels) =
    [reverseOperationKey step | level <- levels, step <- level]

{- | Project the validated plan onto its reverse form for one verb.

Frames are visited innermost-first (the reverse of chain descent order), and
within a frame the steps are reversed. A @PreserveOnReverse@ step never appears,
which is how the durable host root stays inside the plan with an explicit
preserve policy instead of being removed by either verb's projection.
-}
teardownPlan ::
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId frame ->
    ProjectVerb verb ->
    TeardownPlan scope planId frame verb
teardownPlan plan current verb =
    TeardownPlan
        verb
        False
        (stablePlanSnapshotDigest (renderSnapshot plan))
        currentId
        frames
        levels
  where
    currentId = currentFrameId current
    steps = NonEmpty.toList (forward plan)
    frames =
        dropWhile
            (/= currentId)
            (map fst (NonEmpty.toList (topologyFrameOrder (topology plan))))
    levels =
        [ level
        | frame <- reverse frames
        , let level =
                reverse
                    (mapMaybe (reverseStepFor verb (placementFor frame)) (removableIn frame))
        , not (null level)
        ]
    placementFor frame
        | frame == currentId = ReverseLocal currentId
        | otherwise = case frames of
            (_opening : child : _) -> ReverseDescent currentId child
            _ -> ReverseLocal currentId
    removableIn frame =
        [ step
        | step <- steps
        , plannedStepFrameId step == frame
        , plannedStepReversePolicy step /= PreserveOnReverse
        ]

{- | Project only removable effects whose durable Prepared gates were reached by
one failed Up.  The retained verb remains Up, so this value cannot be promoted
to Destroy settlement or used to open a reverse Production intent.  The
duplicate-free evidence is an ordered subset of the plan's own and projected
operations; preservation-only and projected relation keys contribute
reachability evidence but are never turned into cleanup actions.
-}
failedUpTeardownPlanKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId frame ->
    [Text] ->
    Either TeardownError (TeardownPlan scope planId frame VerbUp)
failedUpTeardownPlanKernel plan current reached
    | length reached /= length (nub reached) =
        Left (TeardownReverseDescentRefused "the failed-Up reached set contains a duplicate")
    | reached /= filter (`elem` reached) admitted =
        Left
            ( TeardownReverseDescentRefused
                ( "the failed-Up reached set is not an ordered subset of the admitted plan: admitted "
                    <> Text.intercalate ", " admitted
                    <> ", observed "
                    <> Text.intercalate ", " reached
                )
            )
    | otherwise = Right (TeardownPlan ProjectUp True digest currentId frames levels)
  where
    digest = stablePlanSnapshotDigest (renderSnapshot plan)
    currentId = currentFrameId current
    steps = NonEmpty.toList (forward plan)
    frames =
        dropWhile
            (/= currentId)
            (map fst (NonEmpty.toList (topologyFrameOrder (topology plan))))
    placementFor frame
        | frame == currentId = ReverseLocal currentId
        | otherwise = case frames of
            (_opening : child : _) -> ReverseDescent currentId child
            _ -> ReverseLocal currentId
    selected frame =
        [ step
        | step <- steps
        , plannedStepFrameId step == frame
        , Text.pack (operationKeyText (plannedStepOperationKey step)) `elem` reached
        , plannedStepReversePolicy step /= PreserveOnReverse
        ]
    admitted =
        [ operation
        | frame <- frames
        , step <- steps
        , plannedStepFrameId step == frame
        , operation <-
            Text.pack (operationKeyText (plannedStepOperationKey step))
                : map
                    (Text.pack . operationKeyText)
                    (plannedStepProjectedOperationKeys step)
        ]
    levels =
        [ level
        | frame <- reverse frames
        , let level = reverse (mapMaybe (reverseStepFor ProjectDestroy (placementFor frame)) (selected frame))
        , not (null level)
        ]

reverseStepFor ::
    ProjectVerb verb ->
    ReversePlacement ->
    PlannedStep scope planId configId config ->
    Maybe ReverseStep
reverseStepFor verb placement step =
    ( \action ->
        ReverseStep
            { _reverseIdentity = plannedStepIdentity step
            , reverseOperationKey = plannedStepOperationKey step
            , reverseFrame = plannedStepFrameId step
            , reversePlacement = placement
            , reverseAction = action
            , reversePolicy = plannedStepReversePolicy step
            , reverseRun = plannedStepReverseRun step
            }
    )
        <$> actionFor verb (plannedStepIdentity step)

{- | Select one reverse action from the exact admitted project verb.

@up@ has no reverse work. A VM is stopped by @down@ and deleted by @destroy@;
kind is deleted by both non-up verbs because it has no reliable stop/restart
contract. Every other removable node runs its declared release.
-}
actionFor :: ProjectVerb verb -> StepIdentity -> Maybe TeardownAction
actionFor ProjectUp _ = Nothing
actionFor ProjectDown (CoreStepIdentity DeployVMId) = Just StopFrame
actionFor ProjectDestroy (CoreStepIdentity DeployVMId) = Just DeleteFrame
actionFor ProjectDown (CoreStepIdentity DeployKindId) = Just DeleteCluster
actionFor ProjectDestroy (CoreStepIdentity DeployKindId) = Just DeleteCluster
actionFor ProjectDown _ = Just ReleaseResource
actionFor ProjectDestroy _ = Just ReleaseResource

-- ---------------------------------------------------------------------------
-- The forest

data NodeState
    = -- | destroy-only: the stopped provider is not yet reachable
      PreDescentPending
    | -- | this node's own step waits on its deeper frame
      ChildrenPending
    | -- | this node's own step is schedulable
      SelfPending
    | -- | released, or classified foreign/refused and left untouched
      Settled
    | -- | attempted and failed; the parent stays blocked
      SelfFailed
    deriving (Eq, Show)

data Node = Node
    { nodeStep :: ReverseStep
    , nodeState :: NodeState
    , nodeChildren :: [Node]
    , nodeObservation :: Maybe TeardownOutcome
    }

{- | A live teardown forest. Produced only by 'openTeardownForest' and advanced
only by the branch-specific attempt functions, so there is no way to fabricate
one at an arbitrary position or apply one branch's outcome to another.
-}
data TeardownForest scope planId frame verb
    = TeardownForest (TeardownPlan scope planId frame verb) [Node]

type role TeardownForest nominal nominal nominal nominal

{- | The sole initial forest producer.

Consumes the already-bound projection alone. A node for a provider frame under
@destroy@ starts in 'PreDescentPending', because after a `down` that provider is
stopped and its retained children are unreachable until it is started again.
-}
openTeardownForest ::
    TeardownPlan scope planId frame verb ->
    Either TeardownError (TeardownForest scope planId frame verb)
openTeardownForest projection@(TeardownPlan verb failedUp _ _ _ levels)
    | ProjectUp <- verb, not failedUp = Left TeardownProjectUpHasNoReverse
    | null levels = Left (TeardownPlanEmpty (projectVerbName verb))
    | otherwise = Right (TeardownForest projection (nest verb levels))

{- | Nest the per-frame levels so the deepest frame's nodes precede every node
in the next frame out. Levels arrive innermost-first, so the fold attaches each
level to the one already built beneath it.

The first reverse node owns that attachment: regardless of which forward node
declared the descent, no current-frame reverse effect may run before the child
subtree settles. A VM provider then owns the reverse prefix acquired after it,
preventing failure in that prefix from exposing the provider's stop/delete
action.
-}
nest :: ProjectVerb verb -> [[ReverseStep]] -> [Node]
nest verb = foldl attach []
  where
    attach deeper level = retainFrameOwner (attachDeeper deeper level)

    attachDeeper deeper level = case level of
        [] -> []
        first : rest -> makeNode deeper first : map (makeNode []) rest

    retainFrameOwner nodes = case break (isFrameAction . reverseAction . nodeStep) nodes of
        (prefix, owner : suffix) ->
            let children = prefix ++ nodeChildren owner
             in owner
                    { nodeState = initialState verb (nodeStep owner) children
                    , nodeChildren = children
                    }
                    : suffix
        _ -> nodes

    makeNode children step =
        Node
            { nodeStep = step
            , nodeState = initialState verb step children
            , nodeChildren = children
            , nodeObservation = Nothing
            }

isFrameAction :: TeardownAction -> Bool
isFrameAction action = action == StopFrame || action == DeleteFrame

initialState :: ProjectVerb verb -> ReverseStep -> [Node] -> NodeState
initialState verb step children
    | needsPreDescent verb step children = PreDescentPending
    | null children = SelfPending
    | otherwise = ChildrenPending

{- | Only a @destroy@ of a provider frame that still has retained children needs
the pre-descent reachability step; a @down@ never descends past a stopped
provider, and a childless node has nothing to reach.
-}
needsPreDescent :: ProjectVerb verb -> ReverseStep -> [Node] -> Bool
needsPreDescent ProjectUp _ _ = False
needsPreDescent ProjectDown _ _ = False
needsPreDescent ProjectDestroy step children =
    reverseAction step == DeleteFrame && not (null children)

-- | Nodes that have not settled, deepest first.
teardownForestOutstanding :: TeardownForest scope planId frame verb -> [Text]
teardownForestOutstanding (TeardownForest _ nodes) = concatMap outstandingIn nodes
  where
    outstandingIn node =
        concatMap outstandingIn (nodeChildren node)
            ++ [reverseKey (nodeStep node) | nodeState node /= Settled]

-- | Every node that was attempted and failed, with its reported cause.
teardownForestFailures :: TeardownForest scope planId frame verb -> [(Text, Text)]
teardownForestFailures (TeardownForest _ nodes) = concatMap failuresIn nodes
  where
    failuresIn node =
        concatMap failuresIn (nodeChildren node)
            ++ [ (reverseKey (nodeStep node), Text.pack detail)
               | nodeState node == SelfFailed
               , Just (TeardownFailed detail) <- [nodeObservation node]
               ]

{- | Nodes settled as compatible-unowned or policy-refused. They were left
untouched, which is why they do not block completion but are still reported.
-}
teardownForestForeign :: TeardownForest scope planId frame verb -> [(Text, Text)]
teardownForestForeign (TeardownForest _ nodes) = concatMap foreignIn nodes
  where
    foreignIn node =
        concatMap foreignIn (nodeChildren node)
            ++ [ (reverseKey (nodeStep node), Text.pack detail)
               | nodeState node == Settled
               , Just observation <- [nodeObservation node]
               , detail <- case observation of
                    TeardownForeignRetained value -> [value]
                    TeardownRefused value -> [value]
                    _ -> []
               ]

-- ---------------------------------------------------------------------------
-- Scheduling

-- | A path to one node: the index at each level from the roots down.
type NodePath = [Int]

{- | The exhaustive next-work result. It has no public constructors; callers
must go through 'eliminateTeardownProgress', so neither branch can be wrapped or
skipped.
-}
data TeardownProgress scope planId frame verb
    = ProgressCompleted (CompletedTeardownForest scope planId frame verb)
    | ProgressWork (TeardownAuthorizationPoint scope planId frame verb)

type role TeardownProgress nominal nominal nominal nominal

{- | Proof that every node of this forest settled. Only 'nextTeardownWork'
produces one, and only for a forest with no outstanding and no failed node.
-}
data CompletedTeardownForest scope planId frame verb
    = CompletedTeardownForest
        (ProjectVerb verb)
        Text
        Text
        [(OperationKey, TeardownOutcome)]

type role CompletedTeardownForest nominal nominal nominal nominal

-- | The exact terminal observations, in projected child-first order.
completedForestTerminalObservations ::
    CompletedTeardownForest scope planId frame verb ->
    [(OperationKey, TeardownOutcome)]
completedForestTerminalObservations (CompletedTeardownForest _ _ _ observations) = observations

{- | Authority to attempt exactly one step of exactly one forest. It retains the
forest it came from, so it cannot be replayed against a different one.
-}
data TeardownAuthorizationPoint scope planId frame verb
    = TeardownAuthorizationPoint
        (TeardownForest scope planId frame verb)
        NodePath
        Node
        Bool

type role TeardownAuthorizationPoint nominal nominal nominal nominal

authorizationPointStep :: TeardownAuthorizationPoint scope planId frame verb -> ReverseStep
authorizationPointStep (TeardownAuthorizationPoint _ _ node _) = nodeStep node

authorizationPointKey :: TeardownAuthorizationPoint scope planId frame verb -> Text
authorizationPointKey = reverseKey . authorizationPointStep

-- | The destroy-only step that makes a stopped provider teardown-reachable.
newtype PreDescentStep scope planId frame verb
    = PreDescentStep (TeardownAuthorizationPoint scope planId frame verb)

type role PreDescentStep nominal nominal nominal nominal

preDescentStepKey :: PreDescentStep scope planId frame verb -> Text
preDescentStepKey (PreDescentStep point) = authorizationPointKey point

-- | The frame whose provider this reachability step makes reachable again.
preDescentStepFrame :: PreDescentStep scope planId frame verb -> Text
preDescentStepFrame (PreDescentStep point) = reverseFrame (authorizationPointStep point)

-- | Proof that this node's exact child set has settled.
newtype SettledChildren scope planId frame = SettledChildren [Text]

type role SettledChildren nominal nominal nominal

settledChildrenKeys :: SettledChildren scope planId frame -> [Text]
settledChildrenKeys (SettledChildren keys) = keys

-- | The private cursor retained only by a local-work package.
newtype TeardownCursor scope planId frame verb = TeardownCursor ReverseStep

type role TeardownCursor nominal nominal nominal nominal

{- | One exhaustive ordinary-work result. Its constructors are private, and
'eliminateTeardownWork' is the only reader, so local execution and recursive
descent cannot be interchanged.
-}
data TeardownWork scope planId frame verb where
    LocalTeardownWork ::
        LocalWork scope planId frame verb ->
        TeardownWork scope planId frame verb
    DescentTeardownWork ::
        DescentWork scope planId frame (childFrame :: Type) verb ->
        TeardownWork scope planId frame verb

type role TeardownWork nominal nominal nominal nominal

{- | Local execution authority for one offered node. It privately retains both
the originating forest point and its cursor; this is the only public value from
which a reverse key, action, policy, or runner can be projected.
-}
data LocalWork scope planId frame verb
    = LocalWork
        (TeardownAuthorizationPoint scope planId frame verb)
        (TeardownCursor scope planId frame verb)

type role LocalWork nominal nominal nominal nominal

{- | Recursive routing authority for the immediate topology edge below the
opening frame. The child index is existential outside 'eliminateTeardownWork'.
-}
data DescentWork scope planId frame (childFrame :: Type) verb
    = DescentWork
        (TeardownAuthorizationPoint scope planId frame verb)
        Text
        Text
        (TeardownPlan scope planId childFrame verb)

type role DescentWork nominal nominal nominal nominal nominal

localWorkAction :: LocalWork scope planId frame verb -> TeardownAction
localWorkAction (LocalWork _ (TeardownCursor step)) = reverseAction step

-- | This node's plan operation key.
localWorkKey :: LocalWork scope planId frame verb -> Text
localWorkKey (LocalWork _ (TeardownCursor step)) = reverseKey step

localWorkOperationKey :: LocalWork scope planId frame verb -> OperationKey
localWorkOperationKey (LocalWork _ (TeardownCursor step)) = reverseOperationKey step

-- | The reverse policy the node's forward step declared.
localWorkPolicy :: LocalWork scope planId frame verb -> ReversePolicy
localWorkPolicy (LocalWork _ (TeardownCursor step)) = reversePolicy step

{- | The reverse effect this node's own forward step declared with
'HostBootstrap.Step.reversedBy'. 'Nothing' means it declared none: either the
core adapter owns it (@CoreManagedReverse@) or it acquired nothing this frame
must release. Exposed only through 'LocalWork', so a caller driving the forest
cannot invoke a descendant node's callback before entering that child frame.
-}
localWorkRun ::
    LocalWork scope planId frame verb ->
    Maybe (HostConfig -> TeardownAction -> IO TeardownOutcome)
localWorkRun (LocalWork _ (TeardownCursor step)) = reverseRun step

-- | The exact opening frame from which this descent edge leaves.
descentWorkParentFrame :: DescentWork scope planId frame childFrame verb -> Text
descentWorkParentFrame (DescentWork _ parent _ _) = parent

-- | The exact immediate topology child into which this descent enters.
descentWorkChildFrame :: DescentWork scope planId frame childFrame verb -> Text
descentWorkChildFrame (DescentWork _ _ child _) = child

{- | Eliminate a descent through the exact child projection retained by the
forest. No caller-supplied frame name or independently admitted 'CurrentFrame'
can select another subtree.
-}
withDescentWorkSubtree ::
    DescentWork scope planId frame childFrame verb ->
    (TeardownPlan scope planId childFrame verb -> result) ->
    result
withDescentWorkSubtree (DescentWork _ _ _ childProjection) use = use childProjection

descentWorkOperationKeyTexts ::
    DescentWork scope planId frame childFrame verb ->
    [Text]
descentWorkOperationKeyTexts (DescentWork _ _ _ childProjection) =
    map (Text.pack . operationKeyText) (projectedOperationKeys childProjection)

-- | The exhaustive eliminator for ordinary local-versus-descent work.
eliminateTeardownWork ::
    TeardownWork scope planId frame verb ->
    (LocalWork scope planId frame verb -> result) ->
    (forall (childFrame :: Type). DescentWork scope planId frame childFrame verb -> result) ->
    result
eliminateTeardownWork work onLocal onDescent = case work of
    LocalTeardownWork local -> onLocal local
    DescentTeardownWork descent -> onDescent descent

{- | Find the next schedulable step, or prove the forest is complete.

Depth-first and child-first: a node's own step is offered only once every one of
its children has settled. A failed node is not re-offered — it is terminal for
this forest — but it keeps its parent blocked, while its unrelated siblings stay
schedulable.
-}
nextTeardownWork ::
    TeardownForest scope planId frame verb ->
    TeardownProgress scope planId frame verb
nextTeardownWork forest@(TeardownForest (TeardownPlan verb _ digest frame _ _) nodes) =
    case firstJust [searchAll FreshWork [] nodes, searchAll RetryWork [] nodes] of
        Just (path, node, preDescent) ->
            ProgressWork (TeardownAuthorizationPoint forest path node preDescent)
        Nothing ->
            ProgressCompleted
                ( CompletedTeardownForest
                    verb
                    digest
                    frame
                    (terminalObservations nodes)
                )
  where
    searchAll pass prefix =
        firstJust . zipWith (\index node -> search pass (prefix ++ [index]) node) [0 ..]
    search pass path node = case nodeState node of
        PreDescentPending | pass == FreshWork -> Just (path, node, True)
        SelfPending | pass == FreshWork -> Just (path, node, False)
        -- A failed node is offered again, but only after every unrelated
        -- sibling has had its turn: that is what keeps the rest of the cleanup
        -- draining while its exact parent stays blocked, and it is why a forest
        -- containing a failure can never report itself complete.
        SelfFailed | pass == RetryWork -> Just (path, node, False)
        ChildrenPending ->
            case searchAll pass path (nodeChildren node) of
                Just found -> Just found
                Nothing
                    | pass == FreshWork
                    , all ((== Settled) . nodeState) (nodeChildren node) ->
                        Just (path, node, False)
                    | otherwise -> Nothing
        _ -> Nothing

{- | Two scheduling passes: everything not yet attempted, then everything that
failed. Without the split a depth-first search would keep re-offering the first
failure and starve its siblings.
-}
data SchedulingPass = FreshWork | RetryWork
    deriving (Eq)

firstJust :: [Maybe a] -> Maybe a
firstJust values = case [value | Just value <- values] of
    (value : _) -> Just value
    [] -> Nothing

terminalObservations :: [Node] -> [(OperationKey, TeardownOutcome)]
terminalObservations = concatMap observationsIn
  where
    observationsIn node =
        terminalObservations (nodeChildren node)
            ++ [ (reverseOperationKey (nodeStep node), observation)
               | nodeState node == Settled
               , Just observation <- [nodeObservation node]
               ]

-- | The exhaustive eliminator. There is no other way to read a progress value.
eliminateTeardownProgress ::
    TeardownProgress scope planId frame verb ->
    (CompletedTeardownForest scope planId frame verb -> result) ->
    (TeardownAuthorizationPoint scope planId frame verb -> result) ->
    result
eliminateTeardownProgress progress onCompleted onWork = case progress of
    ProgressCompleted completed -> onCompleted completed
    ProgressWork point -> onWork point

{- | The private eliminator of an authorization point.

It exposes exactly one of two things: the destroy-only pre-descent reachability
step, or the settled-child proof paired with an exhaustive ordinary-work sum. A
caller cannot construct either branch, so it cannot claim children settled when
they have not, invent a reachability step for a @down@, or send descent work to
the local runner.
-}
withTeardownAuthorization ::
    TeardownAuthorizationPoint scope planId frame verb ->
    (PreDescentStep scope planId frame verb -> result) ->
    (SettledChildren scope planId frame -> TeardownWork scope planId frame verb -> result) ->
    result
withTeardownAuthorization point@(TeardownAuthorizationPoint _ _ node preDescent) onPreDescent onOrdinary
    | preDescent = onPreDescent (PreDescentStep point)
    | otherwise =
        onOrdinary
            (SettledChildren [reverseKey (nodeStep child) | child <- nodeChildren node])
            (ordinaryWork point (nodeStep node))

ordinaryWork ::
    TeardownAuthorizationPoint scope planId frame verb ->
    ReverseStep ->
    TeardownWork scope planId frame verb
ordinaryWork point step = case reversePlacement step of
    ReverseLocal _ -> LocalTeardownWork (LocalWork point (TeardownCursor step))
    ReverseDescent parent child ->
        DescentTeardownWork
            (DescentWork point parent child (descentProjection point child))

{- | Reindex the exact suffix already retained by a parent forest at its
immediate child. The child index is introduced only by the private
'DescentWork' constructor, so descriptive frame text never escapes as
authority.
-}
descentProjection ::
    TeardownAuthorizationPoint scope planId frame verb ->
    Text ->
    TeardownPlan scope planId childFrame verb
descentProjection (TeardownAuthorizationPoint (TeardownForest parentProjection _) _ _ _) child =
    case parentProjection of
        TeardownPlan verb failedUp digest _ frames levels ->
            let exactChildFrames = dropWhile (/= child) frames
             in TeardownPlan
                    verb
                    failedUp
                    digest
                    child
                    exactChildFrames
                    [ map (placeForChild exactChildFrames) level
                    | level <- levels
                    , any ((`elem` exactChildFrames) . reverseFrame) level
                    ]
  where
    placeForChild exactChildFrames step =
        step
            { reversePlacement =
                if reverseFrame step == child
                    then ReverseLocal child
                    else case exactChildFrames of
                        (_ : immediate : _) -> ReverseDescent child immediate
                        _ -> ReverseLocal child
            }

-- ---------------------------------------------------------------------------
-- Attempting one step

{- | Record one attempt and return the successor forest.

A successor is returned on **every** outcome, including failure, so the caller
can keep draining independent siblings instead of aborting the whole cleanup.
-}
advanceAuthorizationPoint ::
    TeardownAuthorizationPoint scope planId frame verb ->
    TeardownOutcome ->
    TeardownForest scope planId frame verb
advanceAuthorizationPoint (TeardownAuthorizationPoint forest path _ preDescent) outcome =
    let TeardownForest projection nodes = forest
     in TeardownForest projection (updateAt path nodes)
  where
    updateAt [] nodes = nodes
    updateAt (index : rest) nodes =
        [ if position == index then apply rest node else node
        | (position, node) <- zip [0 ..] nodes
        ]
    apply [] node = advance node
    apply rest node = node{nodeChildren = updateAt rest (nodeChildren node)}

    advance node
        | preDescent = case outcome of
            TeardownReleased -> node{nodeState = descendState node, nodeObservation = Nothing}
            TeardownForeignRetained _ -> terminalNode node outcome
            TeardownRefused _ -> terminalNode node outcome
            TeardownFailed _ -> failedNode node outcome
        | otherwise = case outcome of
            TeardownReleased -> terminalNode node outcome
            TeardownForeignRetained _ -> terminalNode node outcome
            TeardownRefused _ -> terminalNode node outcome
            TeardownFailed _ -> failedNode node outcome

    -- A successful pre-descent exposes the children; a childless node would not
    -- have needed one, so this is always the children-pending state.
    descendState node
        | null (nodeChildren node) = SelfPending
        | otherwise = ChildrenPending

    terminalNode node observation =
        node{nodeState = Settled, nodeObservation = Just observation}
    failedNode node observation =
        node{nodeState = SelfFailed, nodeObservation = Just observation}

-- | Advance exactly the forest that produced this pre-descent step.
attemptPreDescentStep ::
    PreDescentStep scope planId frame verb ->
    TeardownOutcome ->
    TeardownForest scope planId frame verb
attemptPreDescentStep (PreDescentStep point) = advanceAuthorizationPoint point

-- | Advance exactly the forest that produced this local-work package.
attemptLocalWork ::
    LocalWork scope planId frame verb ->
    TeardownOutcome ->
    TeardownForest scope planId frame verb
attemptLocalWork (LocalWork point _) = advanceAuthorizationPoint point

{- | Join the exact settled child proof retained by this descent continuation.

The proof is compared with the private child projection before any state is
changed. On success every exact child terminal observation is imported in one
transition; a sibling, ancestor, reordered observation sequence, or different
plan/verb proof advances nothing.
-}
settleDescentWork ::
    DescentWork scope planId frame childFrame verb ->
    SubtreeSettled scope planId childFrame verb ->
    Either TeardownError (TeardownForest scope planId frame verb)
settleDescentWork (DescentWork point _ _ childProjection) settled = do
    validateSubtreeSettled childProjection settled
    pure (importChildObservations point (subtreeSettledTerminalObservations settled))

-- | Record only a failed descent; raw success cannot advance this branch.
failDescentWork ::
    DescentWork scope planId frame childFrame verb ->
    Text ->
    TeardownForest scope planId frame verb
failDescentWork (DescentWork point _ _ childProjection) detail =
    failChildObservations
        point
        (projectedOperationKeys childProjection)
        (TeardownFailed (Text.unpack detail))

failChildObservations ::
    TeardownAuthorizationPoint scope planId frame verb ->
    [OperationKey] ->
    TeardownOutcome ->
    TeardownForest scope planId frame verb
failChildObservations (TeardownAuthorizationPoint (TeardownForest projection nodes) _ _ _) operations failure =
    TeardownForest projection (map failNode nodes)
  where
    failNode node =
        let children = map failNode (nodeChildren node)
         in if reverseOperationKey (nodeStep node) `elem` operations
                then
                    node
                        { nodeState = SelfFailed
                        , nodeChildren = children
                        , nodeObservation = Just failure
                        }
                else node{nodeChildren = children}

importChildObservations ::
    TeardownAuthorizationPoint scope planId frame verb ->
    [(OperationKey, TeardownOutcome)] ->
    TeardownForest scope planId frame verb
importChildObservations (TeardownAuthorizationPoint (TeardownForest projection nodes) _ _ _) observations =
    TeardownForest projection (map importNode nodes)
  where
    importNode node =
        let children = map importNode (nodeChildren node)
         in case lookup (reverseOperationKey (nodeStep node)) observations of
                Just observation ->
                    node
                        { nodeState = Settled
                        , nodeChildren = children
                        , nodeObservation = Just observation
                        }
                Nothing -> node{nodeChildren = children}

{- | Drive one forest to completion, or report the nodes that never settled.

The scheduling policy lives here rather than at the call site: the forest is what
knows the child-first ordering, the destroy-only pre-descent step, and which
nodes are outstanding. A lifecycle verb supplies one handler for each closed
work branch and a reporter for its row; it never receives an unclassified
'TeardownAuthorizationPoint'.

A node that failed is __not__ retried. 'nextTeardownWork' re-offers it after its
unrelated siblings have drained — which is what keeps the rest of the cleanup
going — and this loop stops when that happens, returning every node still
outstanding. Retrying inside one run would spin, and the forest could never
complete either way.
-}
driveTeardownForest ::
    TeardownForest scope planId frame verb ->
    (PreDescentStep scope planId frame verb -> IO TeardownOutcome) ->
    (SettledChildren scope planId frame -> LocalWork scope planId frame verb -> IO TeardownOutcome) ->
    ( forall (childFrame :: Type).
      SettledChildren scope planId frame ->
      DescentWork scope planId frame childFrame verb ->
      IO (Either Text (SubtreeSettled scope planId childFrame verb))
    ) ->
    (Text -> TeardownOutcome -> IO ()) ->
    IO (Either [Text] (CompletedTeardownForest scope planId frame verb))
driveTeardownForest forest attemptPreDescent attemptLocal attemptDescent report = go [] forest
  where
    go failed current =
        eliminateTeardownProgress
            (nextTeardownWork current)
            (pure . Right)
            ( \point ->
                let key = authorizationPointKey point
                 in if key `elem` failed
                        then pure (Left (teardownForestOutstanding current))
                        else
                            withTeardownAuthorization
                                point
                                ( \preDescent -> do
                                    outcome <- attemptPreDescent preDescent
                                    finish failed key outcome (attemptPreDescentStep preDescent outcome)
                                )
                                ( \settled work ->
                                    eliminateTeardownWork
                                        work
                                        ( \local -> do
                                            outcome <- attemptLocal settled local
                                            finish failed key outcome (attemptLocalWork local outcome)
                                        )
                                        ( \descent -> do
                                            result <- attemptDescent settled descent
                                            case result of
                                                Left detail ->
                                                    let outcome = TeardownFailed (Text.unpack detail)
                                                     in finishDescentFailure
                                                            failed
                                                            key
                                                            (descentWorkOperationKeyTexts descent)
                                                            outcome
                                                            (failDescentWork descent detail)
                                                Right childSettled ->
                                                    case settleDescentWork descent childSettled of
                                                        Left settlementFailure ->
                                                            let detail = Text.pack (teardownErrorMessage settlementFailure)
                                                                outcome = TeardownFailed (Text.unpack detail)
                                                             in finishDescentFailure
                                                                    failed
                                                                    key
                                                                    (descentWorkOperationKeyTexts descent)
                                                                    outcome
                                                                    (failDescentWork descent detail)
                                                        Right next -> do
                                                            mapM_
                                                                (uncurry reportTerminal)
                                                                (subtreeSettledTerminalObservations childSettled)
                                                            go failed next
                                        )
                                )
            )

    finish failed key outcome next = do
        report key outcome
        go
            (failed ++ [key | isTeardownFailure outcome])
            next

    finishDescentFailure failed key blockedKeys outcome next = do
        report key outcome
        go
            (failed ++ blockedKeys)
            next

    reportTerminal operation outcome =
        report (Text.pack (operationKeyText operation)) outcome

isTeardownFailure :: TeardownOutcome -> Bool
isTeardownFailure (TeardownFailed _) = True
isTeardownFailure _ = False

-- ---------------------------------------------------------------------------
-- Settlement

{- | Proof that one exact frame-bound reverse subtree reached a terminal
observation for every projected operation, in exact child-first order.

The constructors are hidden and all indices are nominal. Released,
foreign-retained, and refused observations remain distinct; a failed or
unresolved node cannot enter this package.
-}
data SubtreeSettled scope planId frame verb
    = SubtreeSettled
        (ProjectVerb verb)
        Text
        Text
        [(OperationKey, TeardownOutcome)]

type role SubtreeSettled nominal nominal nominal nominal

instance Show (SubtreeSettled scope planId frame verb) where
    show (SubtreeSettled verb digest frame observations) =
        "SubtreeSettled "
            <> show verb
            <> " "
            <> show digest
            <> " "
            <> show frame
            <> " "
            <> show (length observations)

subtreeSettledPlanDigest :: SubtreeSettled scope planId frame verb -> Text
subtreeSettledPlanDigest (SubtreeSettled _ digest _ _) = digest

subtreeSettledOpeningFrame :: SubtreeSettled scope planId frame verb -> Text
subtreeSettledOpeningFrame (SubtreeSettled _ _ frame _) = frame

subtreeSettledVerbName :: SubtreeSettled scope planId frame verb -> Text
subtreeSettledVerbName (SubtreeSettled verb _ _ _) = projectVerbName verb

subtreeSettledTerminalObservations ::
    SubtreeSettled scope planId frame verb ->
    [(OperationKey, TeardownOutcome)]
subtreeSettledTerminalObservations (SubtreeSettled _ _ _ observations) = observations

subtreeSettledReleasedOperationKeys ::
    SubtreeSettled scope planId frame verb ->
    [OperationKey]
subtreeSettledReleasedOperationKeys settled =
    [ operation
    | (operation, TeardownReleased) <- subtreeSettledTerminalObservations settled
    ]

{- | The sole producer of frame-bound subtree settlement.

The completed forest and projection must agree on the exact verb, digest,
opening frame, and ordered operation-key sequence. A set comparison is
deliberately insufficient: missing, extra, duplicate, and reordered terminal
observations all refuse.
-}
verifySubtreeSettled ::
    TeardownPlan scope planId frame verb ->
    CompletedTeardownForest scope planId frame verb ->
    Either TeardownError (SubtreeSettled scope planId frame verb)
verifySubtreeSettled
    projection
    (CompletedTeardownForest completedVerb completedDigest completedFrame observations) = do
        validateCompleted projection completedVerb completedDigest completedFrame observations
        pure
            ( SubtreeSettled
                completedVerb
                completedDigest
                completedFrame
                observations
            )

validateCompleted ::
    TeardownPlan scope planId frame verb ->
    ProjectVerb verb ->
    Text ->
    Text ->
    [(OperationKey, TeardownOutcome)] ->
    Either TeardownError ()
validateCompleted projection@(TeardownPlan projectedVerb _ projectedDigest projectedFrame _ _) completedVerb completedDigest completedFrame observations
    | projectVerbName completedVerb /= projectVerbName projectedVerb =
        Left
            ( TeardownProjectVerbMismatch
                (projectVerbName projectedVerb)
                (projectVerbName completedVerb)
            )
    | completedDigest /= projectedDigest =
        Left (TeardownPlanDigestMismatch projectedDigest completedDigest)
    | completedFrame /= projectedFrame =
        Left (TeardownOpeningFrameMismatch projectedFrame completedFrame)
    | any (isTeardownFailure . snd) observations =
        Left
            ( TeardownNonTerminalObservations
                (renderTerminalObservations observations)
            )
    | actualKeys /= expectedKeys =
        Left
            ( TeardownTerminalObservationsMismatch
                (map (Text.pack . operationKeyText) expectedKeys)
                (map (Text.pack . operationKeyText) actualKeys)
            )
    | otherwise = Right ()
  where
    expectedKeys = projectedOperationKeys projection
    actualKeys = map fst observations

validateSubtreeSettled ::
    TeardownPlan scope planId frame verb ->
    SubtreeSettled scope planId frame verb ->
    Either TeardownError ()
validateSubtreeSettled projection (SubtreeSettled verb digest frame observations) =
    validateCompleted projection verb digest frame observations

{- | Recheck that a settled subtree is the exact unique-root forest. This
verb-polymorphic check gives Down the same nested-frame refusal that
'verifyDestroySettled' necessarily applies before minting destroy evidence.
-}
validateRootSubtreeSettled ::
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId frame ->
    SubtreeSettled scope planId frame verb ->
    Either TeardownError ()
validateRootSubtreeSettled plan current settled
    | roots /= [currentId] = Left (TeardownRootFrameMismatch currentId roots)
    | otherwise = validateSubtreeSettled (teardownPlan plan current verb) settled
  where
    verb = case settled of SubtreeSettled retained _ _ _ -> retained
    currentId = currentFrameId current
    derived = topology plan
    orderedFrames = map fst (NonEmpty.toList (topologyFrameOrder derived))
    children = map snd (topologyParentEdges derived)
    roots = [frame | frame <- orderedFrames, frame `notElem` children]

renderTerminalObservations ::
    [(OperationKey, TeardownOutcome)] ->
    [(Text, TeardownOutcome)]
renderTerminalObservations =
    map (\(operation, outcome) -> (Text.pack (operationKeyText operation), outcome))

renderTeardownObservations :: [(Text, TeardownOutcome)] -> Either TeardownError ByteString
renderTeardownObservations observations =
    either (Left . observationFailure) Right (renderLifecycleObservations (map render observations))
  where
    render (key, outcome) = case outcome of
        TeardownReleased -> (key, "released", "none")
        TeardownForeignRetained detail -> (key, "foreign-retained", Text.pack detail)
        TeardownRefused detail -> (key, "refused", Text.pack detail)
        TeardownFailed detail -> (key, "failed", Text.pack detail)

teardownObservationsFromWire :: ByteString -> Either TeardownError [(Text, TeardownOutcome)]
teardownObservationsFromWire raw = do
    rows <- either (Left . observationFailure) Right (lifecycleObservationsFromWire raw)
    traverse decode rows
  where
    decode (key, status, detail) = case status of
        "released" -> Right (key, TeardownReleased)
        "foreign-retained" -> Right (key, TeardownForeignRetained (Text.unpack detail))
        "refused" -> Right (key, TeardownRefused (Text.unpack detail))
        "failed" -> Right (key, TeardownFailed (Text.unpack detail))
        _ -> Left (TeardownObservationWireRefused "an observation status is unknown")

observationFailure :: HandoffError -> TeardownError
observationFailure = TeardownObservationWireRefused . Text.pack . handoffErrorMessage

{- | Root-only proof that the whole project destroy settled.

Unlike 'SubtreeSettled', this proof has no frame parameter: it is minted only
after the exact admitted plan topology proves the supplied current frame is
its unique root and the subtree observations exactly match the full root
projection.
-}
data DestroySettled scope planId
    = DestroySettled Text [(OperationKey, TeardownOutcome)]

type role DestroySettled nominal nominal

instance Show (DestroySettled scope planId) where
    show (DestroySettled digest observations) =
        "DestroySettled " <> show digest <> " " <> show (length observations)

destroySettledPlanDigest :: DestroySettled scope planId -> Text
destroySettledPlanDigest (DestroySettled digest _) = digest

destroySettledTerminalObservations ::
    DestroySettled scope planId ->
    [(OperationKey, TeardownOutcome)]
destroySettledTerminalObservations (DestroySettled _ observations) = observations

destroySettledReleasedOperationKeys :: DestroySettled scope planId -> [OperationKey]
destroySettledReleasedOperationKeys settled =
    [ operation
    | (operation, TeardownReleased) <- destroySettledTerminalObservations settled
    ]

verifyDestroySettled ::
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId frame ->
    SubtreeSettled scope planId frame VerbDestroy ->
    Either TeardownError (DestroySettled scope planId)
verifyDestroySettled plan current settled
    | roots /= [currentId] = Left (TeardownRootFrameMismatch currentId roots)
    | subtreeSettledPlanDigest settled /= planDigest =
        Left
            ( TeardownPlanDigestMismatch
                planDigest
                (subtreeSettledPlanDigest settled)
            )
    | subtreeSettledOpeningFrame settled /= currentId =
        Left
            ( TeardownOpeningFrameMismatch
                currentId
                (subtreeSettledOpeningFrame settled)
            )
    | actualKeys /= expectedKeys =
        Left
            ( TeardownTerminalObservationsMismatch
                (map (Text.pack . operationKeyText) expectedKeys)
                (map (Text.pack . operationKeyText) actualKeys)
            )
    | otherwise =
        Right
            ( DestroySettled
                planDigest
                (subtreeSettledTerminalObservations settled)
            )
  where
    currentId = currentFrameId current
    derived = topology plan
    orderedFrames = map fst (NonEmpty.toList (topologyFrameOrder derived))
    children = map snd (topologyParentEdges derived)
    roots = [frame | frame <- orderedFrames, frame `notElem` children]
    planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
    rootProjection = teardownPlan plan current ProjectDestroy
    expectedKeys = projectedOperationKeys rootProjection
    actualKeys = map fst (subtreeSettledTerminalObservations settled)

{- | Refine a verb-polymorphic subtree proof to root destroy settlement only
when its retained canonical verb is @destroy@.
-}
settledDestroyEvidence ::
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId frame ->
    SubtreeSettled scope planId frame verb ->
    Maybe (Either TeardownError (DestroySettled scope planId))
settledDestroyEvidence plan current settled@(SubtreeSettled verb _ _ _) = case verb of
    ProjectUp -> Nothing
    ProjectDown -> Nothing
    ProjectDestroy -> Just (verifyDestroySettled plan current settled)

-- ---------------------------------------------------------------------------
-- Failures

data TeardownError
    = -- | @project up@ has no reverse projection by construction
      TeardownProjectUpHasNoReverse
    | -- | the verb whose projection removed nothing at all
      TeardownPlanEmpty Text
    | -- | nodes the plan names that the forest never settled
      TeardownIncomplete [Text]
    | -- | expected and observed stable plan digests
      TeardownPlanDigestMismatch Text Text
    | -- | expected and observed opening frame identifiers
      TeardownOpeningFrameMismatch Text Text
    | -- | expected and observed canonical project verbs
      TeardownProjectVerbMismatch Text Text
    | -- | expected and observed ordered terminal operation keys
      TeardownTerminalObservationsMismatch [Text] [Text]
    | -- | a failed outcome was presented as terminal settlement
      TeardownNonTerminalObservations [(Text, TeardownOutcome)]
    | -- | the supplied current frame and the topology's derived root set
      TeardownRootFrameMismatch Text [Text]
    | -- | durable reverse-descent preparation refused before exposing work
      TeardownReverseDescentRefused Text
    | TeardownObservationWireRefused Text
    deriving (Eq, Show)

teardownErrorMessage :: TeardownError -> String
teardownErrorMessage failure = case failure of
    TeardownProjectUpHasNoReverse ->
        "teardown: project up has no reverse projection"
    TeardownPlanEmpty verb ->
        "teardown: the "
            <> Text.unpack verb
            <> " projection of this plan removes nothing; every step preserves on reverse"
    TeardownIncomplete missing ->
        "teardown: the forest completed without settling "
            <> Text.unpack (Text.intercalate ", " missing)
    TeardownPlanDigestMismatch expected observed ->
        "teardown: plan digest mismatch; expected "
            <> Text.unpack expected
            <> ", observed "
            <> Text.unpack observed
    TeardownOpeningFrameMismatch expected observed ->
        "teardown: opening frame mismatch; expected "
            <> Text.unpack expected
            <> ", observed "
            <> Text.unpack observed
    TeardownProjectVerbMismatch expected observed ->
        "teardown: project verb mismatch; expected "
            <> Text.unpack expected
            <> ", observed "
            <> Text.unpack observed
    TeardownTerminalObservationsMismatch expected observed ->
        "teardown: exact terminal observation order mismatch; expected "
            <> show expected
            <> ", observed "
            <> show observed
    TeardownNonTerminalObservations observations ->
        "teardown: failed observations cannot settle a subtree: " <> show observations
    TeardownRootFrameMismatch current roots ->
        "teardown: current frame "
            <> Text.unpack current
            <> " is not the topology's unique root; roots were "
            <> show roots
    TeardownReverseDescentRefused detail ->
        "teardown: reverse descent refused: " <> Text.unpack detail
    TeardownObservationWireRefused detail ->
        "teardown: observation wire refused: " <> Text.unpack detail
