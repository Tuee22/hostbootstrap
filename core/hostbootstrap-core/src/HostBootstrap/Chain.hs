{- | The recursive/fractal chain interpreter (development_plan_standards § U, § Y).

A project's deploy is an opaque validated 'StepPlan' (see
'HostBootstrap.Step'); this module interprets that plan across the composed
frame stack. @project up@ runs the steps belonging to the /current/ frame, then
hands off @project up@ into the next frame, where the nested binary runs the
same interpreter over its own segment. The descent is fractal — each frame
transition is provision the frame, build/install the @pb@ in it (both are steps
in the current frame's segment), then hand off. The interpreter re-runs the
current frame's full segment on each entry, so a re-run is restartable exactly
when each contributed step's action is itself idempotent.

The descent logic is pure and unit-tested ('nextFrameAfter', 'handoffDispatch',
'renderChain'); 'runChainFromFrame' is the thin effectful seam that runs a
frame's steps and performs the one handoff. The lift context for each transition
is read off the plan itself ('frameDescent'), declared by the step that owns the
boundary, so the interpreter stays provider-agnostic without a second,
independently supplied per-frame resolver (§ W).
-}
module HostBootstrap.Chain (
    renderChain,
    nextFrameAfter,
    handoffDispatch,
    runChainFromFrame,
)
where

import Data.List (intercalate)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lift (
    LiftContext,
    LiftDispatch,
    SelfRef,
    foldLift,
    liftStdin,
    liftSubcommandWithStdin,
 )
import HostBootstrap.Reconcile (
    LifecyclePlan,
    lifecyclePlanSteps,
    stepExecutionFor,
 )
import HostBootstrap.Step (
    StepPlan,
    StepFrame (..),
    chainFrames,
    frameDescent,
    postHandoffStepsForFrame,
    preHandoffStepsForFrame,
    renderChainPlan,
    renderStep,
    runStep,
 )
import System.Exit (ExitCode (ExitSuccess))

{- | Render the chain as its @--dry-run@ plan — the single representation the
interpreter executes (§ W). Pure, so the rendered plan is exactly the value
@runChainFromFrame@ would run.
-}
renderChain :: StepPlan -> String
renderChain = renderChainPlan

{- | The frame the interpreter hands off to after @current@: the next distinct
frame in descent order, or 'Nothing' at the bottom of the recursion (the
innermost frame, or a frame the chain never enters).
-}
nextFrameAfter :: String -> StepPlan -> Maybe StepFrame
nextFrameAfter current plan =
    case dropWhile ((/= current) . frameId) (chainFrames plan) of
        (_ : next : _) -> Just next
        _ -> Nothing

{- | The pure host dispatch for the recursive handoff: invoke @project up@ in the
next frame's lift context. Pure via 'foldLift', so the handoff argv is
unit-tested and honours § K — only the outermost host dispatch names a
resolver-mapped absolute tool; every nested tool is the target's own bare
@$PATH@ name.
-}
handoffDispatch :: SelfRef -> LiftContext -> LiftDispatch
handoffDispatch self ctx = foldLift self ctx handoffArgv

{- | The argv the interpreter hands off into each next frame. Shared by
'handoffDispatch' (the unit-tested pure fold) and 'runChainFromFrame' (the
effectful seam) so the two never drift.
-}
handoffArgv :: [String]
handoffArgv = ["project", "up"]

{- | Interpret the chain from the current frame: run this frame's steps in order
(the provisioning and @pb@ build of the next frame are themselves steps in this
segment), then hand off @project up@ into the next frame. Fails closed on the
first non-zero handoff so a lifting parent sees the failure. Returns @Right ()@
when this frame's segment and its descent complete.
-}
runChainFromFrame ::
    HostConfig ->
    SelfRef ->
    String ->
    LifecyclePlan scope planId ->
    IO (Either String ())
runChainFromFrame cfg self current lifecyclePlan
    -- Fail closed if @current@ is not a frame the chain enters: otherwise
    -- 'stepsForFrame' is empty and 'nextFrameAfter' is 'Nothing', so the descent
    -- would be a silent successful no-op (a config/chain drift, e.g. a topology
    -- frame id absent from the contributed chain).
    | current `notElem` map frameId (chainFrames plan) =
        pure
            ( Left
                ( "project up: current frame "
                    ++ current
                    ++ " is not a frame of the chain (frames: "
                    ++ intercalate ", " (map frameId (chainFrames plan))
                    ++ ")"
                )
            )
    | otherwise = do
        preRan <- runPlanSteps (preHandoffStepsForFrame current plan)
        case preRan of
            Left err -> pure (Left err)
            Right () -> case nextFrameAfter current plan of
                Nothing -> runPostHandoff
                Just next -> descendInto next
  where
    plan = lifecyclePlanSteps lifecyclePlan

    {- Every action receives the descriptor this plan mints for its own node
    (§ U), never a bare 'HostConfig': the step is told the plan digest, its own
    operation key and frame, and its exact ordered dependency prefix, so a step
    that must prepare an effect names its node instead of reconstructing it.

    'stepExecutionFor' refuses a step the plan does not contain. Every step here
    came out of that same plan, so the refusal is unreachable — it is written as
    a fail-closed error rather than a default descriptor because running a step
    under a descriptor the plan never validated is exactly what the seam exists
    to prevent. -}
    runPlanSteps [] = pure (Right ())
    runPlanSteps (step : rest) =
        case stepExecutionFor lifecyclePlan cfg step of
            Nothing ->
                pure
                    ( Left
                        ( "project up: step "
                            ++ renderStep step
                            ++ " is not a node of the plan being interpreted"
                        )
                    )
            Just execution -> runStep step execution >> runPlanSteps rest

    -- Stream the next frame's child config in-place: for a container frame
    -- with config delivery, 'liftStdin' carries the narrowed projection on
    -- the handoff @stdin@ (the entrypoint wrapper writes the sibling before
    -- dispatch); for a VM/local frame it is empty, byte-identical to the
    -- former 'liftSubcommand'. See § X.
    --
    -- The context comes from the plan node that owns the boundary, so the
    -- step announcing the descent and the payload crossing it are one value.
    -- A validated plan always carries one for a frame that has a successor;
    -- the 'Nothing' branch is the total fail-closed reading of that invariant.
    descendInto next =
        case frameDescent current plan of
            Nothing ->
                pure
                    ( Left
                        ( "project up: frame "
                            ++ current
                            ++ " declares no descent into "
                            ++ frameId next
                        )
                    )
            Just nextCtx -> do
                result <- liftSubcommandWithStdin cfg self nextCtx handoffArgv (liftStdin nextCtx)
                case result of
                    Right (ExitSuccess, out, _) -> putStr out >> runPostHandoff
                    -- Surface the nested frame's captured stdout even on failure (it holds
                    -- the frame's step-by-step progress); the stderr becomes the error.
                    Right (_, out, err) -> putStr out >> pure (Left err)
                    Left err -> pure (Left err)

    runPostHandoff = runPlanSteps (postHandoffStepsForFrame current plan)
