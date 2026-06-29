-- | The 'Step' algebra: the lift-chain stream's reuse unit (development_plan_standards § T, § Y).
--
-- A project's deploy is a pure @chain :: cfg -> [Step]@ value (see
-- 'HostBootstrap.Chain'); each 'Step' is one composable action a binary runs and
-- reports inside one execution frame. @hostbootstrap-core@ ships the
-- host-management step kinds ('StepKind'); a project contributes its own kinds
-- through the open 'ProjectStep' seam, interleaving host and workload steps in
-- one @[Step]@.
--
-- A 'Step' carries a pure, renderable shape — a label, the frame it runs in, and
-- its 'StepKind' — plus an effectful 'stepRun' reconcile action. @project up
-- --dry-run@ renders the shape via 'renderChainPlan' without running the action;
-- the recursive interpreter ('HostBootstrap.Chain') runs the action when the
-- binary is in the step's frame. The action stays context-agnostic
-- (@HostConfig -> IO ()@) so a step is lifted purely by /which frame/ the
-- interpreter runs it in (§ U).
module HostBootstrap.Step
  ( -- * Frames
    StepFrame (..),

    -- * Kinds
    StepKind (..),
    stepKindName,

    -- * Steps
    Step (..),
    renderStep,
    renderChainPlan,
    stepsForFrame,
    chainFrames,

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

    -- * Project-extension seam
    projectStep,
  )
where

import HostBootstrap.HostConfig (HostConfig)

-- | The composed frame a step's binary runs in, identified by its topology frame
-- id (the @topologyFrameId@ in the sibling @<project>.dhall@). The recursive
-- interpreter groups a chain into contiguous per-frame segments in chain order;
-- 'frameLabel' is a human label for the dry-run render.
data StepFrame = StepFrame
  { frameId :: String,
    frameLabel :: String
  }
  deriving (Eq, Show)

-- | The kind of a step: a closed core set of host-management kinds plus the open
-- 'ProjectStep' seam for project-contributed kinds. Pure and renderable, so a
-- chain renders without acting.
data StepKind
  = -- | provision a provider VM (Lima on Apple Silicon, Incus on Linux, WSL2 on Windows)
    DeployVM
  | -- | run an @ensure@ reconciler as a chain step (§ L); carries the tool name
    EnsureTool String
  | -- | stage the project source into the next frame
    CopySource
  | -- | build the project binary host-native in the target frame
    BuildPb
  | -- | build the project container image
    BuildImage
  | -- | mint the next frame's child @<project>.dhall@ before the handoff
    ContextInit
  | -- | bring up the kind cluster
    DeployKind
  | -- | install/upgrade the project Helm chart
    DeployChart
  | -- | expose an in-cluster service outward (NodePort)
    ExposePort
  | -- | the open seam: a project-contributed step kind, carrying its name
    ProjectStep String
  deriving (Eq, Show)

-- | A short stable name for a step kind, used in the dry-run render.
stepKindName :: StepKind -> String
stepKindName k = case k of
  DeployVM -> "deploy-vm"
  EnsureTool tool -> "ensure-" ++ tool
  CopySource -> "copy-source"
  BuildPb -> "build-pb"
  BuildImage -> "build-image"
  ContextInit -> "context-init"
  DeployKind -> "deploy-kind"
  DeployChart -> "deploy-chart"
  ExposePort -> "expose-port"
  ProjectStep name -> name

-- | One composable step: the pure renderable shape plus the effectful reconcile
-- action.
data Step = Step
  { stepLabel :: String,
    stepFrame :: StepFrame,
    stepKind :: StepKind,
    stepRun :: HostConfig -> IO ()
  }

-- | The one-line dry-run render of a step (pure): frame, kind, and label.
renderStep :: Step -> String
renderStep s =
  "["
    ++ frameId (stepFrame s)
    ++ "] "
    ++ stepKindName (stepKind s)
    ++ " — "
    ++ stepLabel s

-- | Render an ordered chain as its numbered plan (the @--dry-run@ output). Pure,
-- so the rendered plan is exactly the value the interpreter would execute (§ W).
renderChainPlan :: [Step] -> String
renderChainPlan steps = unlines (zipWith line [1 :: Int ..] steps)
  where
    line n s = show n ++ ". " ++ renderStep s

-- | The steps of a chain that run in a given frame, in chain order. The recursive
-- interpreter runs exactly these "locally" when the binary is in @fid@.
stepsForFrame :: String -> [Step] -> [Step]
stepsForFrame fid = filter ((== fid) . frameId . stepFrame)

-- | The distinct frames a chain descends through, in first-appearance (descent)
-- order. The interpreter runs the head frame's steps, then hands off into the
-- next, and so on.
chainFrames :: [Step] -> [StepFrame]
chainFrames steps = go [] (map stepFrame steps)
  where
    go _ [] = []
    go seen (f : fs)
      | frameId f `elem` seen = go seen fs
      | otherwise = f : go (frameId f : seen) fs

-- Core host-management step constructors. Each fixes the 'StepKind' and takes the
-- label, frame, and reconcile action so a chain reads as data.

-- | A @deploy-vm@ step.
deployVMStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
deployVMStep label frame = Step label frame DeployVM

-- | An @ensure-*@ step (a reconciler invoked in the chain, § L).
ensureStep :: String -> String -> StepFrame -> (HostConfig -> IO ()) -> Step
ensureStep tool label frame = Step label frame (EnsureTool tool)

-- | A @copy-source@ step.
copySourceStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
copySourceStep label frame = Step label frame CopySource

-- | A @build-pb@ step.
buildPbStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
buildPbStep label frame = Step label frame BuildPb

-- | A @build-image@ step.
buildImageStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
buildImageStep label frame = Step label frame BuildImage

-- | A @context-init@ step (mint the next frame's child config before handoff).
contextInitStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
contextInitStep label frame = Step label frame ContextInit

-- | A @deploy-kind@ step.
deployKindStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
deployKindStep label frame = Step label frame DeployKind

-- | A @deploy-chart@ step.
deployChartStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
deployChartStep label frame = Step label frame DeployChart

-- | An @expose-port@ step.
exposePortStep :: String -> StepFrame -> (HostConfig -> IO ()) -> Step
exposePortStep label frame = Step label frame ExposePort

-- | A project-contributed step (the open seam): the project names its own kind,
-- and the step interleaves freely with the core host-management steps.
projectStep :: String -> String -> StepFrame -> (HostConfig -> IO ()) -> Step
projectStep name label frame = Step label frame (ProjectStep name)
