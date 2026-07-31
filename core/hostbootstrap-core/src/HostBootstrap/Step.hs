{-# LANGUAGE RankNTypes #-}

{- | The opaque validated step/plan algebra.

A project may construct steps only through the smart constructors below and may
hand an interpreter only a validated 'StepPlan'. Core and project identities are
different constructors, rendered labels never select behavior, every step
carries an explicit reverse policy, and validation preserves the declared order
or rejects the plan before effects.

The plan is also where the chain's **descent** and its **reverse** live (§ W).

A step declares with 'descendsVia' how its frame reaches the next frame, and
that one 'LiftContext' carries both the provider dispatch and the child-config
projection streamed on the handoff @stdin@ (§ X). Because exactly one step of
every frame but the innermost must declare it, the step that announces the child
config and the value that delivers it are the same plan node — a @context-init@
label can no longer disagree with an independently supplied projection.

A step declares with 'reversedBy' the effect that releases what it acquired, so
the node that creates a resource is the node that removes it. @project down@ and
@project destroy@ are then two verb-indexed projections of this same plan
("HostBootstrap.Teardown") rather than a whole-project hook beside it, and a
@PreserveOnReverse@ step enters neither.
-}
module HostBootstrap.Step (
    -- * Frames
    StepFrame (..),

    -- * Identities and policies
    CoreStepId (..),
    ProjectStepId,
    projectStepId,
    StepIdentity (..),
    ReversePolicy (..),
    OperationKey,
    operationKeyText,

    -- * Opaque steps
    Step,
    StepKind,
    stepLabel,
    stepFrame,
    stepKind,
    stepKindName,
    stepIdentity,
    stepReversePolicy,
    stepOperationKey,
    runStep,
    isDeployKindStep,
    isDeployVMStep,
    renderStep,

    -- * Plan-owned descent
    descendsVia,
    stepDescents,
    frameDescent,

    -- * Plan-owned reverse
    TeardownAction (..),
    TeardownOutcome (..),
    reversedBy,
    stepReverses,
    stepReverse,

    -- * Opaque validated plans
    StepPlan,
    StepPlanError (..),
    mkStepPlan,
    stepPlanSteps,
    renderChainPlan,
    stepsForFrame,
    preHandoffStepsForFrame,
    postHandoffStepsForFrame,
    chainFrames,
    stepDependencies,

    -- * Core host-management step constructors
    deployVMStep,
    ensureStep,
    copySourceStep,
    buildPbStep,
    buildImageStep,
    contextInitStep,
    deployKindStep,
    deployChartStep,
    exposePortStep,
    postHandoffStep,

    -- * Project-extension seam
    projectStep,
)
where

import Data.List (group, sort)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lift (LiftContext)

{- | One execution frame. The id is semantic; the label is presentation only.
Validation rejects two labels for the same id.
-}
data StepFrame = StepFrame
    { frameId :: String
    , frameLabel :: String
    }
    deriving (Eq, Show)

-- | Closed identities owned by core.
data CoreStepId
    = DeployVMId
    | EnsureToolId String
    | CopySourceId
    | BuildPbId
    | BuildImageId
    | ContextInitId
    | DeployKindId
    | DeployChartId
    | ExposePortId
    | PostHandoffId String
    deriving (Eq, Ord, Show)

-- | A validated project-owned identity. Its constructor is hidden.
newtype ProjectStepId = ProjectStepId String
    deriving (Eq, Ord, Show)

-- | Validate a project identity. It need not avoid core spellings because its
-- namespace is disjoint, but it must be a stable non-empty token.
projectStepId :: String -> Either String ProjectStepId
projectStepId raw
    | null raw = Left "project step identity must not be empty"
    | any invalid raw = Left ("project step identity is not a stable token: " ++ show raw)
    | otherwise = Right (ProjectStepId raw)
  where
    invalid c = not (c == '-' || c == '_' || c == '.' || c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z')

-- | Core and project identities cannot collide even when they render alike.
data StepIdentity
    = CoreStepIdentity CoreStepId
    | ProjectStepIdentity ProjectStepId
    deriving (Eq, Ord, Show)

{- | What one reverse step does to its resource.

'StopFrame' and 'DeleteFrame' are the single point where the two teardown verbs
differ: @down@ stops a provider frame so the guest and its disk survive,
@destroy@ deletes it. 'DeleteCluster' is used by __both__, because kind has no
reliable stop contract. Which one a step gets is derived by
"HostBootstrap.Teardown" from the plan and the verb; the step's own reverse
action receives it rather than choosing it.
-}
data TeardownAction
    = -- | provider frame: stop it, keeping the guest and its disk
      StopFrame
    | -- | provider frame: delete it and its disk
      DeleteFrame
    | -- | the ephemeral kind cluster; its removal set is empty
      DeleteCluster
    | -- | any other acquired resource this run owns
      ReleaseResource
    deriving (Eq, Ord, Show)

{- | What one reverse attempt observed. Only 'TeardownFailed' blocks completion:
compatible unowned state and a policy refusal both leave the object untouched
and are recorded rather than retried (§ Y).
-}
data TeardownOutcome
    = TeardownReleased
    | -- | compatible unowned state; not ours, so not torn down
      TeardownForeignRetained String
    | -- | an otherwise legal transition declined by policy
      TeardownRefused String
    | TeardownFailed String
    deriving (Eq, Show)

{- | The declared reverse behavior for a step. It is the classification the
verb-indexed reverse projection reads; requiring it prevents a mutating step
from entering a finalized plan without an explicit reverse decision. The
__effect__ that carries it out is attached separately with 'reversedBy', and
'mkStepPlan' checks the two agree.
-}
data ReversePolicy
    = PreserveOnReverse
    | CoreManagedReverse
    | ProjectManagedReverse
    deriving (Eq, Ord, Show)

-- | Stable namespaced operation key derived only from the typed identity.
newtype OperationKey = OperationKey String
    deriving (Eq, Ord, Show)

operationKeyText :: OperationKey -> String
operationKeyText (OperationKey value) = value

-- | Render-only kind view. The constructor is hidden.
data StepKind
    = CoreKind CoreStepId
    | ProjectKind ProjectStepId
    deriving (Eq, Show)

-- | One opaque step.
data Step = Step
    { internalStepLabel :: String
    , internalStepFrame :: StepFrame
    , internalStepKind :: StepKind
    , internalStepReversePolicy :: ReversePolicy
    , internalStepRun :: HostConfig -> IO ()
    , internalStepDescent :: [LiftContext]
    -- ^ The descent this step declares out of its own frame. A list rather than
    -- a 'Maybe' so a second declaration is /retained/ as a construction
    -- conflict and rejected by 'mkStepPlan', instead of silently replacing the
    -- first.
    , internalStepReverse :: [HostConfig -> TeardownAction -> IO TeardownOutcome]
    -- ^ The reverse effect this step declares, retained the same way.
    }

stepLabel :: Step -> String
stepLabel = internalStepLabel

stepFrame :: Step -> StepFrame
stepFrame = internalStepFrame

stepKind :: Step -> StepKind
stepKind = internalStepKind

stepIdentity :: Step -> StepIdentity
stepIdentity step =
    case internalStepKind step of
        CoreKind identity -> CoreStepIdentity identity
        ProjectKind identity -> ProjectStepIdentity identity

stepReversePolicy :: Step -> ReversePolicy
stepReversePolicy = internalStepReversePolicy

stepOperationKey :: Step -> OperationKey
stepOperationKey step =
    OperationKey $
        case stepIdentity step of
            CoreStepIdentity identity -> "core:" ++ stepKindName (CoreKind identity)
            ProjectStepIdentity identity -> "project:" ++ stepKindName (ProjectKind identity)

runStep :: Step -> HostConfig -> IO ()
runStep = internalStepRun

{- | Declare how this step's frame descends into the next frame of the chain
(§ U): the provider dispatch and, for a boundary that delivers one, the child
config streamed in place on the handoff @stdin@ (§ X).

Exactly one step of every frame but the innermost declares this, so the descent
is a node of the same validated plan the forward traversal and the reverse
projection are taken from (§ W) rather than a separately supplied per-frame
resolver. A second declaration — on this step or on a sibling in the same frame
— is a plan error, not a silent replacement.
-}
descendsVia :: LiftContext -> Step -> Step
descendsVia context step =
    step{internalStepDescent = internalStepDescent step ++ [context]}

-- | The descents this step declares. More than one is a construction conflict.
stepDescents :: Step -> [LiftContext]
stepDescents = internalStepDescent

{- | Declare the effect that releases what this step acquired.

The reverse projection already knew /that/ a step must be undone and in what
order (its 'ReversePolicy' and frame position); this is the effect itself, so
the node that acquires a resource is the node that releases it rather than a
separately supplied whole-project hook. The action receives the verb-derived
'TeardownAction', which is the only thing that differs between @down@ and
@destroy@ for a given node.

A @PreserveOnReverse@ step may not declare one: it never enters a reverse
projection at all, so the effect would be dead code rather than a policy, and
'mkStepPlan' rejects it. A @CoreManagedReverse@ node /may/ declare one, and it
then takes precedence over the core adapter for that node — the demo's direct
Linux GPU lane needs exactly that, because its @deploy-kind@ cluster lives in a
frame the metal host has no kube toolchain for and is reached instead through
the project image.

Declaring none is legal and means the step acquired nothing this frame must
release — @build-pb@, for instance, leaves a binary inside a frame that its own
parent releases.
-}
reversedBy ::
    (HostConfig -> TeardownAction -> IO TeardownOutcome) ->
    Step ->
    Step
reversedBy action step =
    step{internalStepReverse = internalStepReverse step ++ [action]}

{- | The reverse effects this step declares. More than one is a construction
conflict.
-}
stepReverses :: Step -> [HostConfig -> TeardownAction -> IO TeardownOutcome]
stepReverses = internalStepReverse

{- | The single reverse effect a validated step declares, if any. Total because
'mkStepPlan' has already rejected a second declaration.
-}
stepReverse :: Step -> Maybe (HostConfig -> TeardownAction -> IO TeardownOutcome)
stepReverse step = case internalStepReverse step of
    (action : _) -> Just action
    [] -> Nothing

isDeployKindStep :: Step -> Bool
isDeployKindStep step =
    case internalStepKind step of
        CoreKind DeployKindId -> True
        _ -> False

{- | Whether this step provisions a provider frame. The reverse projection needs
it because the provider is the one resource whose teardown action differs
between @down@ (stop, keeping the guest and its disk) and @destroy@ (delete).
-}
isDeployVMStep :: Step -> Bool
isDeployVMStep step =
    case internalStepKind step of
        CoreKind DeployVMId -> True
        _ -> False

-- | Stable presentation name; it is never used as identity.
stepKindName :: StepKind -> String
stepKindName kind =
    case kind of
        CoreKind identity ->
            case identity of
                DeployVMId -> "deploy-vm"
                EnsureToolId tool -> "ensure-" ++ tool
                CopySourceId -> "copy-source"
                BuildPbId -> "build-pb"
                BuildImageId -> "build-image"
                ContextInitId -> "context-init"
                DeployKindId -> "deploy-kind"
                DeployChartId -> "deploy-chart"
                ExposePortId -> "expose-port"
                PostHandoffId name -> "post-handoff-" ++ name
        ProjectKind (ProjectStepId name) -> name

renderStep :: Step -> String
renderStep step =
    "["
        ++ frameId (stepFrame step)
        ++ "] "
        ++ stepKindName (stepKind step)
        ++ " — "
        ++ stepLabel step

-- | An opaque non-empty plan whose declared order and frame traversal agree.
newtype StepPlan = StepPlan [Step]

data StepPlanError
    = EmptyStepPlan
    | EmptyFrameId Int
    | EmptyStepLabel Int
    | DuplicateStepIdentities [StepIdentity]
    | ConflictingFrameLabels String [String]
    | NonContiguousFrameReturn String [String]
    | PostHandoffBeforeDescentComplete Int
    | PostHandoffForUnknownFrame Int String
    | -- | a frame that descends into another declared no 'descendsVia'
      MissingFrameDescent String
    | -- | more than one 'descendsVia' was declared for the same frame
      DuplicateFrameDescent String Int
    | -- | the innermost frame has nowhere to descend to
      DescentFromInnermostFrame String
    | -- | a post-handoff hook runs after the descent; it cannot declare one
      DescentOnPostHandoffStep Int
    | -- | more than one 'reversedBy' was declared for the same step
      DuplicateStepReverse StepIdentity Int
    | -- | the step never enters a reverse projection, so its effect is dead
      ReverseOnPreservedStep StepIdentity
    deriving (Eq, Show)

{- | Validate the exact declared sequence. Normal steps must form contiguous
frame segments. Post-handoff hooks may appear only as a final suffix and may
refer only to a frame already present in the descent sequence. Every frame but
the innermost declares exactly one descent, and the innermost declares none, so
the interpreter's handoff context is a projection of this plan rather than a
separate resolver.
-}
mkStepPlan :: [Step] -> Either StepPlanError StepPlan
mkStepPlan [] = Left EmptyStepPlan
mkStepPlan steps
    | Just (index, _) <- firstIndexed (null . frameId . stepFrame) steps =
        Left (EmptyFrameId index)
    | Just (index, _) <- firstIndexed (null . stepLabel) steps =
        Left (EmptyStepLabel index)
    | not (null duplicateIdentities) =
        Left (DuplicateStepIdentities duplicateIdentities)
    | Just (fid, labels) <- conflictingLabels =
        Left (ConflictingFrameLabels fid labels)
    | Just index <- postBeforeNormal =
        Left (PostHandoffBeforeDescentComplete index)
    | Just (index, fid) <- unknownPostFrame =
        Left (PostHandoffForUnknownFrame index fid)
    | Just fid <- returnedFrame =
        Left (NonContiguousFrameReturn fid normalFrameIds)
    | Just index <- postHandoffDescent =
        Left (DescentOnPostHandoffStep index)
    | Just failure <- descentFailure =
        Left failure
    | Just failure <- reverseFailure =
        Left failure
    | otherwise = Right (StepPlan steps)
  where
    duplicateIdentities = duplicates (map stepIdentity steps)
    framePairs = [(frameId frame, frameLabel frame) | frame <- map stepFrame steps]
    conflictingLabels =
        firstJust
            [ let labels = unique [label | (candidate, label) <- framePairs, candidate == fid]
               in if length labels > 1 then Just (fid, labels) else Nothing
            | fid <- unique (map fst framePairs)
            ]
    (normalSteps, postSteps) = break isPostHandoffStep steps
    postBeforeNormal =
        case firstIndexed (not . isPostHandoffStep) postSteps of
            Nothing -> Nothing
            Just (offset, _) -> Just (length normalSteps + offset)
    normalFrameIds = map (frameId . stepFrame) normalSteps
    descentFrameIds = unique normalFrameIds
    unknownPostFrame =
        firstJust
            [ if frameId (stepFrame step) `elem` descentFrameIds
                then Nothing
                else Just (index, frameId (stepFrame step))
            | (index, step) <- zip [length normalSteps + 1 ..] postSteps
            ]
    returnedFrame = firstReturnedFrame normalFrameIds
    postHandoffDescent =
        fmap
            (\(offset, _) -> length normalSteps + offset)
            (firstIndexed (not . null . stepDescents) postSteps)
    {- Every frame that has a successor declares exactly one descent; the
    innermost declares none, because there is nothing below it to name. -}
    {- A declared reverse effect must be able to run, and there must be at most
    one of it. A preserved step is never projected, so an effect declared there
    could never fire. -}
    reverseFailure =
        firstJust
            [ case (stepReversePolicy step, length (stepReverses step)) of
                (_, 0) -> Nothing
                (PreserveOnReverse, _) -> Just (ReverseOnPreservedStep (stepIdentity step))
                (_, 1) -> Nothing
                (_, declared) -> Just (DuplicateStepReverse (stepIdentity step) declared)
            | step <- steps
            ]
    descentFailure = firstJust (map descentFailureFor (zip [1 :: Int ..] descentFrameIds))
    descentFailureFor (position, fid)
        | position == length descentFrameIds =
            if declared > 0 then Just (DescentFromInnermostFrame fid) else Nothing
        | declared == 0 = Just (MissingFrameDescent fid)
        | declared > 1 = Just (DuplicateFrameDescent fid declared)
        | otherwise = Nothing
      where
        declared =
            length
                [ context
                | step <- normalSteps
                , frameId (stepFrame step) == fid
                , context <- stepDescents step
                ]

stepPlanSteps :: StepPlan -> [Step]
stepPlanSteps (StepPlan steps) = steps

renderChainPlan :: StepPlan -> String
renderChainPlan plan = unlines (zipWith line [1 :: Int ..] (stepPlanSteps plan))
  where
    line number step = show number ++ ". " ++ renderStep step

stepsForFrame :: String -> StepPlan -> [Step]
stepsForFrame fid = filter ((== fid) . frameId . stepFrame) . stepPlanSteps

preHandoffStepsForFrame :: String -> StepPlan -> [Step]
preHandoffStepsForFrame fid = filter (not . isPostHandoffStep) . stepsForFrame fid

postHandoffStepsForFrame :: String -> StepPlan -> [Step]
postHandoffStepsForFrame fid = filter isPostHandoffStep . stepsForFrame fid

{- | The descent context frame @fid@ declared, or 'Nothing' for the innermost
frame (and for a frame the chain never enters). Validation guarantees at most
one, so this is total rather than a first-wins choice.
-}
frameDescent :: String -> StepPlan -> Maybe LiftContext
frameDescent fid plan =
    case concatMap stepDescents (preHandoffStepsForFrame fid plan) of
        (context : _) -> Just context
        [] -> Nothing

chainFrames :: StepPlan -> [StepFrame]
chainFrames plan = foldl addFrame [] normalSteps
  where
    normalSteps = takeWhile (not . isPostHandoffStep) (stepPlanSteps plan)
    addFrame frames step
        | frameId (stepFrame step) `elem` map frameId frames = frames
        | otherwise = frames ++ [stepFrame step]

-- | The exact validated prefix a step depends on. Because plan identities are
-- unique, the target is unambiguous; a step outside the plan has no dependency
-- witness.
stepDependencies :: StepPlan -> Step -> [StepIdentity]
stepDependencies plan target =
    case break ((== stepIdentity target) . stepIdentity) (stepPlanSteps plan) of
        (before, _ : _) -> map stepIdentity before
        (_, []) -> []

isPostHandoffStep :: Step -> Bool
isPostHandoffStep step =
    case stepKind step of
        CoreKind (PostHandoffId _) -> True
        _ -> False

firstIndexed :: (a -> Bool) -> [a] -> Maybe (Int, a)
firstIndexed predicate values =
    case filter (predicate . snd) (zip [1 ..] values) of
        [] -> Nothing
        found : _ -> Just found

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (Nothing : rest) = firstJust rest
firstJust (Just value : _) = Just value

unique :: (Eq a) => [a] -> [a]
unique = foldl add []
  where
    add seen value
        | value `elem` seen = seen
        | otherwise = seen ++ [value]

duplicates :: (Ord a) => [a] -> [a]
duplicates values = [value | value : _ : _ <- group (sort values)]

firstReturnedFrame :: [String] -> Maybe String
firstReturnedFrame [] = Nothing
firstReturnedFrame (firstFrame : rest) = go firstFrame [] rest
  where
    go _ _ [] = Nothing
    go current closed (next : remaining)
        | next == current = go current closed remaining
        | next `elem` closed = Just next
        | otherwise = go next (current : closed) remaining

coreStep ::
    CoreStepId ->
    ReversePolicy ->
    String ->
    StepFrame ->
    (HostConfig -> IO ()) ->
    Step
coreStep identity reversePolicy label frame action =
    Step label frame (CoreKind identity) reversePolicy action [] []

deployVMStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
deployVMStep = coreStep DeployVMId ProjectManagedReverse

ensureStep :: String -> String -> StepFrame -> (HostConfig -> IO ()) -> Step
ensureStep tool = coreStep (EnsureToolId tool) PreserveOnReverse

copySourceStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
copySourceStep = coreStep CopySourceId ProjectManagedReverse

buildPbStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
buildPbStep = coreStep BuildPbId ProjectManagedReverse

buildImageStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
buildImageStep = coreStep BuildImageId ProjectManagedReverse

contextInitStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
contextInitStep = coreStep ContextInitId ProjectManagedReverse

deployKindStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
deployKindStep = coreStep DeployKindId CoreManagedReverse

deployChartStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
deployChartStep = coreStep DeployChartId CoreManagedReverse

exposePortStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
exposePortStep = coreStep ExposePortId CoreManagedReverse

postHandoffStep :: String -> String -> StepFrame -> (HostConfig -> IO ()) -> Step
postHandoffStep name = coreStep (PostHandoffId name) ProjectManagedReverse

projectStep ::
    ProjectStepId ->
    ReversePolicy ->
    String ->
    StepFrame ->
    (HostConfig -> IO ()) ->
    Step
projectStep identity reversePolicy label frame action =
    Step label frame (ProjectKind identity) reversePolicy action [] []
