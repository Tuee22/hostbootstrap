{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The verb-indexed reverse projection and its teardown forest
(the recursive-lifecycle-command phase, @development_plan_standards.md@ § Y).

`project down` and `project destroy` are not two hand-written cleanup routines.
They are two **projections of the same validated plan**, and this module is
where that is made structural:

* 'TeardownPlan' is indexed by the verb, so a @Down@ projection cannot be passed
  where a @Destroy@ projection is required. The two differ in exactly one place —
  a provider frame is *stopped* by @down@ and *deleted* by @destroy@ — and in
  neither does a step whose reverse policy is @PreserveOnReverse@ appear at all,
  which is how the host-root @.data@ stays inside the one plan with an explicit
  preserve policy rather than being excluded by a special case at the call site.
* The kind cluster is deleted by **both** verbs, because kind has no reliable
  stop/restart contract. Its removal set is empty, so no filesystem path is
  removed with it.
* 'openTeardownForest' is the **sole** initial producer of a forest. There is no
  cursor, authorization point, or completed-forest value before it, and the
  forest it opens is bound to the exact plan it was derived from.

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
**completed Destroy** forest can enter 'verifyDestroySettled', which is the sole
producer of 'DestroySettled' — the proof
@HostBootstrap.Lifecycle.Mode.destroySettledClosure@ requires before Production
mode may be released.

A foreign or refused observation is not a failure: § Y classifies compatible
unowned state as a `ForeignResult` and a policy decision as a `SafetyRefusal`,
and neither is torn down. Both settle their node — the run never owned the
object — and both are recorded on the forest so the report can name them.
-}
module HostBootstrap.Teardown (
    -- * The two verbs
    DownVerb,
    DestroyVerb,
    TeardownVerb,
    downVerb,
    destroyVerb,
    teardownVerbName,

    -- * The reverse projection
    TeardownAction (..),
    TeardownPlan,
    teardownPlan,
    teardownPlanVerbName,
    teardownPlanStepKeys,
    teardownPlanActions,
    runTeardownProjection,

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
    completedForestSettledKeys,
    TeardownAuthorizationPoint,
    authorizationPointKey,
    PreDescentStep,
    preDescentStepKey,
    preDescentStepFrame,
    SettledChildren,
    settledChildrenKeys,
    TeardownCursor,
    teardownCursorAction,
    teardownCursorKey,
    teardownCursorFrame,
    teardownCursorPolicy,
    teardownCursorRun,
    withTeardownAuthorization,

    -- * Attempting one step
    TeardownOutcome (..),
    attemptTeardownStep,
    driveTeardownForest,

    -- * Settlement
    DestroySettled,
    destroySettledPlanDigest,
    destroySettledReleasedKeys,
    verifyDestroySettled,
    settledDestroyEvidence,

    -- * Failures
    TeardownError (..),
    teardownErrorMessage,
) where

import Control.Exception (SomeException, displayException)
import Control.Exception.Safe (try)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Reconcile (
    LifecyclePlan,
    lifecyclePlanDigest,
    lifecyclePlanSteps,
 )
import HostBootstrap.Step (
    ReversePolicy (..),
    Step,
    TeardownAction (..),
    TeardownOutcome (..),
    chainFrames,
    frameId,
    isDeployKindStep,
    isDeployVMStep,
    operationKeyText,
    stepFrame,
    stepOperationKey,
    stepPlanSteps,
    stepReverse,
    stepReversePolicy,
 )

-- ---------------------------------------------------------------------------
-- The verbs

data DownVerb
data DestroyVerb

{- | Which reverse projection is being taken. The GADT is what gives
'TeardownPlan' and every downstream forest value a distinct type per verb, so an
@up@-failure unwind or a @down@ cannot be handed to a destroy-only consumer.
-}
data TeardownVerb verb where
    DownTeardown :: TeardownVerb DownVerb
    DestroyTeardown :: TeardownVerb DestroyVerb

downVerb :: TeardownVerb DownVerb
downVerb = DownTeardown

destroyVerb :: TeardownVerb DestroyVerb
destroyVerb = DestroyTeardown

teardownVerbName :: TeardownVerb verb -> Text
teardownVerbName DownTeardown = "down"
teardownVerbName DestroyTeardown = "destroy"

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
    { reverseKey :: Text
    , reverseFrame :: Text
    , reverseAction :: TeardownAction
    , reversePolicy :: ReversePolicy
    , reverseRun :: Maybe (HostConfig -> TeardownAction -> IO TeardownOutcome)
    }

{- | The pure, verb-indexed reverse projection of one validated plan.

Derived only from a 'LifecyclePlan', so the identities it names are exactly the
plan's own operation keys — the structural property § W requires of the forward
and reverse projections.
-}
data TeardownPlan scope planId verb
    = TeardownPlan (TeardownVerb verb) Text [[ReverseStep]]

teardownPlanVerbName :: TeardownPlan scope planId verb -> Text
teardownPlanVerbName (TeardownPlan verb _ _) = teardownVerbName verb

{- | The plan's reverse step identities, deepest frame first. Every entry is one
of the forward plan's own operation keys.
-}
teardownPlanStepKeys :: TeardownPlan scope planId verb -> [Text]
teardownPlanStepKeys (TeardownPlan _ _ levels) =
    [reverseKey step | level <- levels, step <- level]

teardownPlanActions :: TeardownPlan scope planId verb -> [(Text, TeardownAction)]
teardownPlanActions (TeardownPlan _ _ levels) =
    [(reverseKey step, reverseAction step) | level <- levels, step <- level]

{- | Run the verb's reverse projection in its own order — deepest frame first,
and within a frame the exact reverse of the forward sequence.

Every effect comes from the plan: a node runs the reverse its own step declared
with 'HostBootstrap.Step.reversedBy', a @CoreManagedReverse@ node that declared
none is handed to the core adapter @onCoreManaged@, and a node that declared
none and is not core-managed acquired nothing this frame must release, so it is
skipped and reported as such. There is no whole-project teardown hook to
disagree with the plan.

A throwing effect becomes 'TeardownFailed' rather than aborting the traversal,
so an unrelated later node still gets its turn — the § Y rule that a refusal or
a failure skips only its own resource.

This drives the pure projection, not the 'TeardownForest'. It is the single-frame
traversal: it visits only the nodes this binary can act on and claims nothing
about deeper frames. The production lifecycle verbs drive the __forest__ instead,
because the forest adds child-first ordering and the destroy-only pre-descent
reachability step, and those are only truthful when the verb recurses into each
descendant frame — which it now does.
-}
runTeardownProjection ::
    TeardownPlan scope planId verb ->
    -- | how the core releases a node whose reverse it owns
    (Text -> TeardownAction -> IO TeardownOutcome) ->
    HostConfig ->
    IO [(Text, Maybe TeardownOutcome)]
runTeardownProjection (TeardownPlan _ _ levels) onCoreManaged cfg =
    mapM attempt [step | level <- levels, step <- level]
  where
    attempt step = do
        outcome <- case (reverseRun step, reversePolicy step) of
            (Just action, _) -> Just <$> guarded (action cfg (reverseAction step))
            (Nothing, CoreManagedReverse) ->
                Just <$> guarded (onCoreManaged (reverseKey step) (reverseAction step))
            (Nothing, _) -> pure Nothing
        pure (reverseKey step, outcome)
    guarded effect = do
        result <- try effect
        pure $ case result of
            Right outcome -> outcome
            Left exc -> TeardownFailed (displayException (exc :: SomeException))

{- | Project the validated plan onto its reverse form for one verb.

Frames are visited innermost-first (the reverse of chain descent order), and
within a frame the steps are reversed. A @PreserveOnReverse@ step never appears,
which is how the durable host root stays inside the plan with an explicit
preserve policy instead of being removed by either verb's projection.
-}
teardownPlan ::
    LifecyclePlan scope planId ->
    TeardownVerb verb ->
    TeardownPlan scope planId verb
teardownPlan plan verb =
    TeardownPlan verb (lifecyclePlanDigest plan) levels
  where
    steps = lifecyclePlanSteps plan
    levels =
        [ level
        | frame <- reverse (map frameId (chainFrames steps))
        , let level = reverse (map (reverseStepFor verb) (removableIn frame))
        , not (null level)
        ]
    removableIn frame =
        [ step
        | step <- stepPlanSteps steps
        , frameId (stepFrame step) == frame
        , stepReversePolicy step /= PreserveOnReverse
        ]

reverseStepFor :: TeardownVerb verb -> Step -> ReverseStep
reverseStepFor verb step =
    ReverseStep
        { reverseKey = Text.pack (operationKeyText (stepOperationKey step))
        , reverseFrame = Text.pack (frameId (stepFrame step))
        , reverseAction = actionFor verb step
        , reversePolicy = stepReversePolicy step
        , reverseRun = stepReverse step
        }

actionFor :: TeardownVerb verb -> Step -> TeardownAction
actionFor verb step
    | isDeployVMStep step = case verb of
        DownTeardown -> StopFrame
        DestroyTeardown -> DeleteFrame
    -- kind has no reliable stop/restart contract, so both verbs delete it
    | isDeployKindStep step = DeleteCluster
    | otherwise = ReleaseResource

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
    , nodeNote :: Maybe Text
    }

{- | A live teardown forest. Produced only by 'openTeardownForest' and advanced
only by 'attemptTeardownStep', so there is no way to fabricate one at an
arbitrary position.
-}
data TeardownForest scope planId verb
    = TeardownForest (TeardownVerb verb) Text [Node]

{- | The sole initial forest producer.

Binds the pure reverse projection to the plan it was derived from. A node for a
provider frame under @destroy@ starts in 'PreDescentPending', because after a
`down` that provider is stopped and its retained children are unreachable until
it is started again.
-}
openTeardownForest ::
    LifecyclePlan scope planId ->
    TeardownPlan scope planId verb ->
    Either TeardownError (TeardownForest scope planId verb)
openTeardownForest _plan (TeardownPlan verb digest levels)
    | null levels = Left (TeardownPlanEmpty (teardownVerbName verb))
    | otherwise = Right (TeardownForest verb digest (nest verb levels))

{- | Nest the per-frame levels so the deepest frame's nodes are children of the
next frame out. Levels arrive innermost-first, so the fold attaches each level
to the one already built beneath it.
-}
nest :: TeardownVerb verb -> [[ReverseStep]] -> [Node]
nest verb = foldl attach []
  where
    attach deeper level =
        [ Node
            { nodeStep = step
            , nodeState = initialState verb step (childrenOf step)
            , nodeChildren = childrenOf step
            , nodeNote = Nothing
            }
        | step <- level
        ]
      where
        -- The step that provisions the deeper frame lives in *this* level, so
        -- the deeper nodes hang under it. With no frame step in this level the
        -- first one owns them, which preserves the child-first ordering.
        childrenOf step
            | Just owner <- frameOwner level
            , reverseKey step == reverseKey owner =
                deeper
            | otherwise = []

frameOwner :: [ReverseStep] -> Maybe ReverseStep
frameOwner steps =
    case [step | step <- steps, isFrameAction (reverseAction step)] of
        (step : _) -> Just step
        [] -> case steps of
            (step : _) -> Just step
            [] -> Nothing

isFrameAction :: TeardownAction -> Bool
isFrameAction action = action == StopFrame || action == DeleteFrame

initialState :: TeardownVerb verb -> ReverseStep -> [Node] -> NodeState
initialState verb step children
    | needsPreDescent verb step children = PreDescentPending
    | null children = SelfPending
    | otherwise = ChildrenPending

{- | Only a @destroy@ of a provider frame that still has retained children needs
the pre-descent reachability step; a @down@ never descends past a stopped
provider, and a childless node has nothing to reach.
-}
needsPreDescent :: TeardownVerb verb -> ReverseStep -> [Node] -> Bool
needsPreDescent DownTeardown _ _ = False
needsPreDescent DestroyTeardown step children =
    isFrameAction (reverseAction step) && not (null children)

-- | Nodes that have not settled, deepest first.
teardownForestOutstanding :: TeardownForest scope planId verb -> [Text]
teardownForestOutstanding (TeardownForest _ _ nodes) = concatMap outstandingIn nodes
  where
    outstandingIn node =
        concatMap outstandingIn (nodeChildren node)
            ++ [reverseKey (nodeStep node) | nodeState node /= Settled]

-- | Every node that was attempted and failed, with its reported cause.
teardownForestFailures :: TeardownForest scope planId verb -> [(Text, Text)]
teardownForestFailures (TeardownForest _ _ nodes) = concatMap failuresIn nodes
  where
    failuresIn node =
        concatMap failuresIn (nodeChildren node)
            ++ [ (reverseKey (nodeStep node), note)
               | nodeState node == SelfFailed
               , Just note <- [nodeNote node]
               ]

{- | Nodes settled as compatible-unowned or policy-refused. They were left
untouched, which is why they do not block completion but are still reported.
-}
teardownForestForeign :: TeardownForest scope planId verb -> [(Text, Text)]
teardownForestForeign (TeardownForest _ _ nodes) = concatMap foreignIn nodes
  where
    foreignIn node =
        concatMap foreignIn (nodeChildren node)
            ++ [ (reverseKey (nodeStep node), note)
               | nodeState node == Settled
               , Just note <- [nodeNote node]
               ]

-- ---------------------------------------------------------------------------
-- Scheduling

-- | A path to one node: the index at each level from the roots down.
type NodePath = [Int]

{- | The exhaustive next-work result. It has no public constructors; callers
must go through 'eliminateTeardownProgress', so neither branch can be wrapped or
skipped.
-}
data TeardownProgress scope planId verb
    = ProgressCompleted (CompletedTeardownForest scope planId verb)
    | ProgressWork (TeardownAuthorizationPoint scope planId verb)

{- | Proof that every node of this forest settled. Only 'nextTeardownWork'
produces one, and only for a forest with no outstanding and no failed node.
-}
data CompletedTeardownForest scope planId verb
    = CompletedTeardownForest (TeardownVerb verb) Text [Text] [(Text, Text)]

-- | The operation keys this forest settled, deepest first.
completedForestSettledKeys :: CompletedTeardownForest scope planId verb -> [Text]
completedForestSettledKeys (CompletedTeardownForest _ _ keys _) = keys

{- | Authority to attempt exactly one step of exactly one forest. It retains the
forest it came from, so it cannot be replayed against a different one.
-}
data TeardownAuthorizationPoint scope planId verb
    = TeardownAuthorizationPoint
        (TeardownForest scope planId verb)
        NodePath
        Node
        Bool

authorizationPointKey :: TeardownAuthorizationPoint scope planId verb -> Text
authorizationPointKey (TeardownAuthorizationPoint _ _ node _) = reverseKey (nodeStep node)

-- | The destroy-only step that makes a stopped provider teardown-reachable.
newtype PreDescentStep scope planId verb = PreDescentStep ReverseStep

preDescentStepKey :: PreDescentStep scope planId verb -> Text
preDescentStepKey (PreDescentStep step) = reverseKey step

-- | The frame whose provider this reachability step makes reachable again.
preDescentStepFrame :: PreDescentStep scope planId verb -> Text
preDescentStepFrame (PreDescentStep step) = reverseFrame step

-- | Proof that this node's exact child set has settled.
newtype SettledChildren scope planId = SettledChildren [Text]

settledChildrenKeys :: SettledChildren scope planId -> [Text]
settledChildrenKeys (SettledChildren keys) = keys

-- | The cursor for one ordinary teardown step.
data TeardownCursor scope planId verb = TeardownCursor ReverseStep

teardownCursorAction :: TeardownCursor scope planId verb -> TeardownAction
teardownCursorAction (TeardownCursor step) = reverseAction step

-- | This node's plan operation key.
teardownCursorKey :: TeardownCursor scope planId verb -> Text
teardownCursorKey (TeardownCursor step) = reverseKey step

{- | The frame the plan placed this node in. A driver compares it against the
frame it is running in: a node of a deeper frame is released by the binary that
can see it, reached through the descent the plan declares, not by this one.
-}
teardownCursorFrame :: TeardownCursor scope planId verb -> Text
teardownCursorFrame (TeardownCursor step) = reverseFrame step

-- | The reverse policy the node's forward step declared.
teardownCursorPolicy :: TeardownCursor scope planId verb -> ReversePolicy
teardownCursorPolicy (TeardownCursor step) = reversePolicy step

{- | The reverse effect this node's own forward step declared with
'HostBootstrap.Step.reversedBy'. 'Nothing' means it declared none: either the
core adapter owns it (@CoreManagedReverse@) or it acquired nothing this frame
must release. Exposed so a caller driving the __forest__ runs exactly the effects
'runTeardownProjection' would, rather than resolving them beside the plan.
-}
teardownCursorRun ::
    TeardownCursor scope planId verb ->
    Maybe (HostConfig -> TeardownAction -> IO TeardownOutcome)
teardownCursorRun (TeardownCursor step) = reverseRun step

{- | Find the next schedulable step, or prove the forest is complete.

Depth-first and child-first: a node's own step is offered only once every one of
its children has settled. A failed node is not re-offered — it is terminal for
this forest — but it keeps its parent blocked, while its unrelated siblings stay
schedulable.
-}
nextTeardownWork :: TeardownForest scope planId verb -> TeardownProgress scope planId verb
nextTeardownWork forest@(TeardownForest verb digest nodes) =
    case firstJust [searchAll FreshWork [] nodes, searchAll RetryWork [] nodes] of
        Just (path, node, preDescent) ->
            ProgressWork (TeardownAuthorizationPoint forest path node preDescent)
        Nothing ->
            ProgressCompleted
                ( CompletedTeardownForest
                    verb
                    digest
                    (settledKeys nodes)
                    (teardownForestForeign forest)
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

settledKeys :: [Node] -> [Text]
settledKeys = concatMap keysIn
  where
    keysIn node =
        settledKeys (nodeChildren node)
            ++ [reverseKey (nodeStep node) | nodeState node == Settled]

-- | The exhaustive eliminator. There is no other way to read a progress value.
eliminateTeardownProgress ::
    TeardownProgress scope planId verb ->
    (CompletedTeardownForest scope planId verb -> result) ->
    (TeardownAuthorizationPoint scope planId verb -> result) ->
    result
eliminateTeardownProgress progress onCompleted onWork = case progress of
    ProgressCompleted completed -> onCompleted completed
    ProgressWork point -> onWork point

{- | The private eliminator of an authorization point.

It exposes exactly one of two things: the destroy-only pre-descent reachability
step, or the settled-child proof paired with the ordinary step's cursor. A
caller cannot construct either branch, so it cannot claim children settled when
they have not, nor invent a reachability step for a @down@.
-}
withTeardownAuthorization ::
    TeardownAuthorizationPoint scope planId verb ->
    (PreDescentStep scope planId verb -> result) ->
    (SettledChildren scope planId -> TeardownCursor scope planId verb -> result) ->
    result
withTeardownAuthorization (TeardownAuthorizationPoint _ _ node preDescent) onPreDescent onOrdinary
    | preDescent = onPreDescent (PreDescentStep (nodeStep node))
    | otherwise =
        onOrdinary
            (SettledChildren [reverseKey (nodeStep child) | child <- nodeChildren node])
            (TeardownCursor (nodeStep node))

-- ---------------------------------------------------------------------------
-- Attempting one step

{- | Record one attempt and return the successor forest.

A successor is returned on **every** outcome, including failure, so the caller
can keep draining independent siblings instead of aborting the whole cleanup.
-}
attemptTeardownStep ::
    TeardownAuthorizationPoint scope planId verb ->
    TeardownOutcome ->
    TeardownForest scope planId verb
attemptTeardownStep (TeardownAuthorizationPoint forest path _ preDescent) outcome =
    let TeardownForest verb digest nodes = forest
     in TeardownForest verb digest (updateAt path nodes)
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
            TeardownReleased -> node{nodeState = descendState node}
            TeardownForeignRetained detail -> foreignNode node detail
            TeardownRefused detail -> foreignNode node detail
            TeardownFailed detail -> failedNode node detail
        | otherwise = case outcome of
            TeardownReleased -> node{nodeState = Settled, nodeNote = Nothing}
            TeardownForeignRetained detail -> foreignNode node detail
            TeardownRefused detail -> foreignNode node detail
            TeardownFailed detail -> failedNode node detail

    -- A successful pre-descent exposes the children; a childless node would not
    -- have needed one, so this is always the children-pending state.
    descendState node
        | null (nodeChildren node) = SelfPending
        | otherwise = ChildrenPending

    foreignNode node detail = node{nodeState = Settled, nodeNote = Just (Text.pack detail)}
    failedNode node detail = node{nodeState = SelfFailed, nodeNote = Just (Text.pack detail)}

{- | Drive one forest to completion, or report the nodes that never settled.

The scheduling policy lives here rather than at the call site: the forest is what
knows the child-first ordering, the destroy-only pre-descent step, and which
nodes are outstanding, so a lifecycle verb supplies only the effect for one
offered node and a reporter for its row.

A node that failed is __not__ retried. 'nextTeardownWork' re-offers it after its
unrelated siblings have drained — which is what keeps the rest of the cleanup
going — and this loop stops when that happens, returning every node still
outstanding. Retrying inside one run would spin, and the forest could never
complete either way.
-}
driveTeardownForest ::
    TeardownForest scope planId verb ->
    -- | attempt exactly the offered node
    (TeardownAuthorizationPoint scope planId verb -> IO TeardownOutcome) ->
    -- | report one node's row
    (Text -> TeardownOutcome -> IO ()) ->
    IO (Either [Text] (CompletedTeardownForest scope planId verb))
driveTeardownForest forest attempt report = go [] forest
  where
    go failed current =
        eliminateTeardownProgress
            (nextTeardownWork current)
            (pure . Right)
            ( \point ->
                let key = authorizationPointKey point
                 in if key `elem` failed
                        then pure (Left (teardownForestOutstanding current))
                        else do
                            outcome <- attempt point
                            report key outcome
                            go
                                (failed ++ [key | isTeardownFailure outcome])
                                (attemptTeardownStep point outcome)
            )

isTeardownFailure :: TeardownOutcome -> Bool
isTeardownFailure (TeardownFailed _) = True
isTeardownFailure _ = False

-- ---------------------------------------------------------------------------
-- Settlement

{- | Proof that a @destroy@ tore down every node the plan named, with no failure
and no unresolved node. It is the settled half of
@ProjectClosureEvidence SettledDestroyClose@; without it, Production mode cannot
be released.
-}
data DestroySettled scope planId
    = DestroySettled Text [Text]

instance Show (DestroySettled scope planId) where
    show (DestroySettled digest keys) =
        "DestroySettled " <> show digest <> " " <> show (length keys)

destroySettledPlanDigest :: DestroySettled scope planId -> Text
destroySettledPlanDigest (DestroySettled digest _) = digest

destroySettledReleasedKeys :: DestroySettled scope planId -> [Text]
destroySettledReleasedKeys (DestroySettled _ keys) = keys

{- | The sole producer of 'DestroySettled'.

It accepts only a **completed Destroy** forest — the type refuses a @Down@
forest outright — and additionally refuses a completed forest that settled fewer
nodes than the plan projected, so a truncated traversal cannot be presented as a
settled destroy.
-}
verifyDestroySettled ::
    TeardownPlan scope planId DestroyVerb ->
    CompletedTeardownForest scope planId DestroyVerb ->
    Either TeardownError (DestroySettled scope planId)
verifyDestroySettled projection (CompletedTeardownForest _ digest settled _)
    | not (null missing) = Left (TeardownIncomplete missing)
    | otherwise = Right (DestroySettled digest settled)
  where
    missing = [key | key <- nub (teardownPlanStepKeys projection), key `notElem` settled]

{- | The verb-dispatching front end a call site driving either projection uses.

A lifecycle verb is written once for both verbs, so it holds a
@TeardownVerb verb@ it cannot case on — the constructors are private, which is
what stops a caller claiming a @Down@ run settled a destroy. This matches on the
verb index inside the module and hands back 'verifyDestroySettled' only on the
destroy branch: a @down@ yields 'Nothing', and there is no other way to reach the
proof.
-}
settledDestroyEvidence ::
    TeardownPlan scope planId verb ->
    CompletedTeardownForest scope planId verb ->
    Maybe (Either TeardownError (DestroySettled scope planId))
settledDestroyEvidence projection@(TeardownPlan verb _ _) completed = case verb of
    DownTeardown -> Nothing
    DestroyTeardown -> Just (verifyDestroySettled projection completed)

-- ---------------------------------------------------------------------------
-- Failures

data TeardownError
    = -- | the verb whose projection removed nothing at all
      TeardownPlanEmpty Text
    | -- | nodes the plan names that the forest never settled
      TeardownIncomplete [Text]
    deriving (Eq, Show)

teardownErrorMessage :: TeardownError -> String
teardownErrorMessage failure = case failure of
    TeardownPlanEmpty verb ->
        "teardown: the "
            <> Text.unpack verb
            <> " projection of this plan removes nothing; every step preserves on reverse"
    TeardownIncomplete missing ->
        "teardown: the forest completed without settling "
            <> Text.unpack (Text.intercalate ", " missing)
