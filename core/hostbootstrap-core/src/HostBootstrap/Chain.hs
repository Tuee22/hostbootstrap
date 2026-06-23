-- | The recursive/fractal chain interpreter (development_plan_standards § U, § Y).
--
-- A project's deploy is the pure @chain :: cfg -> [Step]@ value (see
-- 'HostBootstrap.Step'); this module interprets that @[Step]@ across the composed
-- frame stack. @project up@ runs the steps belonging to the /current/ frame, then
-- hands off @project up@ into the next frame, where the nested binary runs the
-- same interpreter over its own segment. The descent is fractal — each frame
-- transition is provision the frame, build/install the @pb@ in it (both are steps
-- in the current frame's segment), then hand off. The interpreter re-runs the
-- current frame's full segment on each entry, so a re-run is restartable exactly
-- when each contributed step's action is itself idempotent.
--
-- The descent logic is pure and unit-tested ('nextFrameAfter', 'handoffDispatch',
-- 'renderChain'); 'runChainFromFrame' is the thin effectful seam that runs a
-- frame's steps and performs the one handoff. It is parameterised by @liftCtx@,
-- which builds the lift context for a frame from the topology provider and the
-- VM/container identity, so the interpreter stays provider-agnostic.
module HostBootstrap.Chain
  ( renderChain,
    nextFrameAfter,
    handoffDispatch,
    runChainFromFrame,
  )
where

import Data.List (intercalate)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lift
  ( LiftContext,
    LiftDispatch,
    SelfRef,
    foldLift,
    liftSubcommand,
  )
import HostBootstrap.Step
  ( Step (..),
    StepFrame (..),
    chainFrames,
    renderChainPlan,
    stepsForFrame,
  )
import System.Exit (ExitCode (ExitSuccess))

-- | Render the chain as its @--dry-run@ plan — the single representation the
-- interpreter executes (§ W). Pure, so the rendered plan is exactly the value
-- @runChainFromFrame@ would run.
renderChain :: [Step] -> String
renderChain = renderChainPlan

-- | The frame the interpreter hands off to after @current@: the next distinct
-- frame in descent order, or 'Nothing' at the bottom of the recursion (the
-- innermost frame, or a frame the chain never enters).
nextFrameAfter :: String -> [Step] -> Maybe StepFrame
nextFrameAfter current steps =
  case dropWhile ((/= current) . frameId) (chainFrames steps) of
    (_ : next : _) -> Just next
    _ -> Nothing

-- | The pure host dispatch for the recursive handoff: invoke @project up@ in the
-- next frame's lift context. Pure via 'foldLift', so the handoff argv is
-- unit-tested and honours § K — only the outermost host dispatch names a
-- resolver-mapped absolute tool; every nested tool is the target's own bare
-- @$PATH@ name.
handoffDispatch :: SelfRef -> LiftContext -> LiftDispatch
handoffDispatch self ctx = foldLift self ctx handoffArgv

-- | The argv the interpreter hands off into each next frame. Shared by
-- 'handoffDispatch' (the unit-tested pure fold) and 'runChainFromFrame' (the
-- effectful seam) so the two never drift.
handoffArgv :: [String]
handoffArgv = ["project", "up"]

-- | Interpret the chain from the current frame: run this frame's steps in order
-- (the provisioning and @pb@ build of the next frame are themselves steps in this
-- segment), then hand off @project up@ into the next frame. Fails closed on the
-- first non-zero handoff so a lifting parent sees the failure. Returns @Right ()@
-- when this frame's segment and its descent complete.
runChainFromFrame ::
  HostConfig ->
  SelfRef ->
  (StepFrame -> LiftContext) ->
  String ->
  [Step] ->
  IO (Either String ())
runChainFromFrame cfg self liftCtx current steps
  -- Fail closed if @current@ is not a frame the chain enters: otherwise
  -- 'stepsForFrame' is empty and 'nextFrameAfter' is 'Nothing', so the descent
  -- would be a silent successful no-op (a config/chain drift, e.g. a topology
  -- frame id absent from the contributed chain).
  | current `notElem` map frameId (chainFrames steps) =
      pure
        ( Left
            ( "project up: current frame "
                ++ current
                ++ " is not a frame of the chain (frames: "
                ++ intercalate ", " (map frameId (chainFrames steps))
                ++ ")"
            )
        )
  | otherwise = do
      mapM_ (\s -> stepRun s cfg) (stepsForFrame current steps)
      case nextFrameAfter current steps of
        Nothing -> pure (Right ())
        Just next -> do
          result <- liftSubcommand cfg self (liftCtx next) handoffArgv
          case result of
            Right (ExitSuccess, out, _) -> putStr out >> pure (Right ())
            -- Surface the nested frame's captured stdout even on failure (it holds
            -- the frame's step-by-step progress); the stderr becomes the error.
            Right (_, out, err) -> putStr out >> pure (Left err)
            Left err -> pure (Left err)
