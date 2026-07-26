{- | The opaque validated step/plan algebra.

A project may construct steps only through the smart constructors below and may
hand an interpreter only a validated 'StepPlan'. Core and project identities are
different constructors, rendered labels never select behavior, every step
carries an explicit reverse policy, and validation preserves the declared order
or rejects the plan before effects.
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
    renderStep,

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

{- | The declared reverse behavior for a step. It is metadata for the later
receipt-driven teardown interpreter; requiring it now prevents a mutating step
from entering a finalized plan without an explicit reverse decision.
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

isDeployKindStep :: Step -> Bool
isDeployKindStep step =
    case internalStepKind step of
        CoreKind DeployKindId -> True
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
    deriving (Eq, Show)

{- | Validate the exact declared sequence. Normal steps must form contiguous
frame segments. Post-handoff hooks may appear only as a final suffix and may
refer only to a frame already present in the descent sequence.
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
    Step label frame (CoreKind identity) reversePolicy action

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
    Step label frame (ProjectKind identity) reversePolicy action
