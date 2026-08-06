{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

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

import Control.Exception.Safe (throwIO, try)
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Authority (
    InstalledProject,
    authorityErrorMessage,
    brokerEpochWord,
    withFreshBrokerEpoch,
    withRecordedBrokerEpoch,
 )
import HostBootstrap.Harness (SafetyRefusal (SafetyRefusal))
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Session (
    FenceEpoch,
    IntentOrigin (NoHistory),
    OperationSession,
    ProjectPermit,
    SessionError (SessionRecordCorrupt),
    acknowledgeOutcome,
    closeOperationSession,
    establishInitialFence,
    openOperationSession,
    openProjectJournal,
    recoverAbandonedSessions,
    registerOperationIntent,
    sessionErrorMessage,
    withOperationAdvance,
    withStepPreparedGate,
 )
import HostBootstrap.Protected (
    ProtectedSession,
    ProtectedStore,
    protectedErrorMessage,
    withProtectedEntry,
 )
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
    lifecyclePlanDigest,
    lifecyclePlanSteps,
    stepExecutionFor,
 )
import HostBootstrap.Step (
    StepPlan,
    StepFrame (..),
    observationDetail,
    observationSucceeded,
    chainFrames,
    frameDescent,
    postHandoffStepsForFrame,
    preHandoffStepsForFrame,
    renderChainPlan,
    renderStep,
    runStep,
    stepOperationKey,
    operationKeyText,
    StepObservation (StepRefused),
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


{- | The durable journal one chain interpretation runs its nodes against.

It is opened once, before the first node, and carries the broker generation as a
word rather than an epoch: the epoch is bound in a rank-2 continuation that ends
with the exclusive entry, and the entry must not be held across a provider call.
-}
data ChainJournal scope planId
    = ChainJournal
        Word64
        (OperationSession scope planId)
        (FenceEpoch scope planId)
        (ProjectPermit scope planId)

{- | The phase a node publishes /before/ its effect runs. It is deliberately
outside every classifier list, so an invocation killed between the write and the
observation leaves a state a successor refuses to guess about. -}
unknownStepPhase :: Text
unknownStepPhase = "EffectOutcomeUnknown"

{- | The phase a node settles at once its effect returned a definite observation.

A node that reached its target state is @Committed@ — settled, nothing owed. One
that did not is terminal: an operator resolves it and a successor may not retry
it. Which of the three non-success outcomes it was lives in the interpreter's
row, not in the record, because the record's only job is the recovery
classification. -}
settledPhaseFor :: StepObservation -> Text
settledPhaseFor observation
    | observationSucceeded observation = "Committed"
    | otherwise = "StepObservedTerminal"

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
    ProtectedStore ->
    InstalledProject projectId ->
    LifecyclePlan scope planId ->
    IO (Either String ())
runChainFromFrame cfg self current store project lifecyclePlan
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
        -- Open the durable journal for this plan before the first node runs, so
        -- every node of this frame has a registered operation to prepare
        -- against (§ EE). A predecessor killed mid-chain left its session Open;
        -- closing those is this opener's first act, exactly as a new invocation
        -- must.
        opened <- openChainJournal
        case opened of
            Left err -> pure (Left err)
            Right (ChainJournal epochWord sess fence permit) -> do
                outcome <-
                    withRecordedBrokerEpoch epochWord $ \epoch ->
                        Right <$> interpret epoch sess fence permit
                pure (either (Left . Text.unpack . authorityErrorMessage) id outcome)
  where
    plan = lifecyclePlanSteps lifecyclePlan
    planDigest = lifecyclePlanDigest lifecyclePlan

    -- Every node of this frame, in plan order, plus the descent between them.
    frameSteps = preHandoffStepsForFrame current plan ++ postHandoffStepsForFrame current plan

    interpret epoch sess fence permit = do
        preRan <- runPlanSteps epoch sess fence permit (preHandoffStepsForFrame current plan)
        case preRan of
            Left err -> pure (Left err)
            Right afterPre -> case nextFrameAfter current plan of
                Nothing -> runPostHandoff epoch sess fence afterPre
                Just next -> descendInto epoch sess fence afterPre next

    {- Open this interpretation's journal, session, and fence, and register every
    node of this frame, all inside one exclusive entry.

    The broker generation is allocated here and carried onward as a **word**:
    'withFreshBrokerEpoch' binds the epoch in a rank-2 continuation that ends
    with the entry, and the entry must not be held across a provider call. The
    interpreter therefore re-opens the same generation's type identity with
    'withRecordedBrokerEpoch', which needs no session. -}
    openChainJournal = inEntry $ \s -> do
        swept <- recoverAbandonedSessions s planDigest
        case swept of
            Left failure -> pure (Left failure)
            Right _ -> do
                allocated <- withFreshBrokerEpoch s project $ \epoch -> do
                    journal <- openProjectJournal s planDigest
                    case journal of
                        Left failure -> pure (Right (Left failure))
                        Right initial -> do
                            started <-
                                openOperationSession
                                    s
                                    epoch
                                    planDigest
                                    (chainSessionId (brokerEpochWord epoch))
                                    initial
                            case started of
                                Left failure -> pure (Right (Left failure))
                                Right (sess, afterOpen) -> do
                                    settled <- establishInitialFence s planDigest 1
                                    case settled of
                                        Left failure -> pure (Right (Left failure))
                                        Right fence -> do
                                            registered <- registerAll s sess afterOpen frameSteps
                                            pure
                                                ( Right
                                                    ( ChainJournal (brokerEpochWord epoch) sess fence
                                                        <$> registered
                                                    )
                                                )
                pure $ case allocated of
                    Left failure -> Left (SessionRecordCorrupt (authorityErrorMessage failure))
                    Right inner -> inner

    registerAll _ _ permit [] = pure (Right permit)
    registerAll s sess permit (step : rest) = do
        registered <-
            registerOperationIntent
                s
                sess
                (Text.pack (operationKeyText (stepOperationKey step)))
                NoHistory
                permit
        case registered of
            Left failure -> pure (Left failure)
            Right next -> registerAll s sess next rest

    {- This interpretation's session identity.

    A session record is per **invocation**, and 'openOperationSession' refuses an
    identifier that already has a record — a closed one included, because a
    session is not a slot to be reused. The broker generation is allocated fresh
    under the store's exclusive entry and is monotonic, so pairing it with the
    frame gives an identity no later invocation can collide with, and one that
    still names which frame it belonged to. -}
    chainSessionId epochWord =
        Text.pack ("chain-" ++ current ++ "-" ++ show epochWord)

    inEntry :: (forall session. ProtectedSession session -> IO (Either SessionError result)) -> IO (Either String result)
    inEntry action = do
        outcome <- withProtectedEntry store (fmap Right . action)
        pure $ case outcome of
            Left storeFailure -> Left (Text.unpack (protectedErrorMessage storeFailure))
            Right (Left failure) -> Left (sessionErrorMessage failure)
            Right (Right value) -> Right value

    {- Every action receives the descriptor this plan mints for its own node
    (§ U), never a bare 'HostConfig': the step is told the plan digest, its own
    operation key and frame, and its exact ordered dependency prefix, so a step
    that must prepare an effect names its node instead of reconstructing it.

    'stepExecutionFor' refuses a step the plan does not contain. Every step here
    came out of that same plan, so the refusal is unreachable — it is written as
    a fail-closed error rather than a default descriptor because running a step
    under a descriptor the plan never validated is exactly what the seam exists
    to prevent. -}
    runPlanSteps _ _ _ permit [] = pure (Right permit)
    runPlanSteps epoch sess fence permit (step : rest) =
        case stepExecutionFor lifecyclePlan cfg step of
            Nothing ->
                pure
                    ( Left
                        ( "project up: step "
                            ++ renderStep step
                            ++ " is not a node of the plan being interpreted"
                        )
                    )
            Just execution -> do
                ran <- runNode epoch sess fence permit step execution
                case ran of
                    Left err -> pure (Left err)
                    Right (observation, afterNode)
                        -- What the node observed becomes its own row. A
                        -- conflict, an unsupported backend, and a refusal are
                        -- distinct outcomes an operator resolves differently, so
                        -- they stay distinct here instead of collapsing into one
                        -- undifferentiated failure (§ W). All three are terminal
                        -- for the chain: the node did not reach its target
                        -- state, so a later node that depends on it would act on
                        -- a precondition that does not hold.
                        | observationSucceeded observation ->
                            runPlanSteps epoch sess fence afterNode rest
                        | otherwise -> do
                            -- The row names *which* node and *what kind* of
                            -- outcome it was, so the three are told apart on the
                            -- way out rather than reduced to "the chain failed".
                            putStrLn ("  " ++ renderRow step observation)
                            pure (Left ("project up: " ++ renderRow step observation))

    {- Run one node as the three-phase transaction § EE requires.

    The ordering is the whole point. The durable unknown phase is recorded
    /inside/ an exclusive entry, before the effect; the effect itself runs
    /outside/ any entry, because a provider call or a cluster bring-up must not
    hold the store's exclusive lock for its duration; and the node is settled
    inside a fresh entry afterwards. So the record that an attempt may have
    happened always precedes the attempt, and a crash at any point leaves a state
    the next invocation's sweep can classify.

    The gate is minted through 'withStepPreparedGate', which reads the plan
    digest and the operation key off this node's own plan-minted descriptor — so
    a node prepares itself and cannot name a sibling. -}
    runNode epoch sess fence permit step execution = do
        prepared <-
            inEntry $ \s ->
                withStepPreparedGate
                    s
                    sess
                    epoch
                    fence
                    execution
                    unknownStepPhase
                    permit
                    (\gate next -> pure (Right (gate, next)))
        case prepared of
            Left err -> pure (Left err)
            Right (gate, afterPrepare) -> do
                {- A step may *report* a refusal or *throw* one. Both are
                definite — the node will not reach its target state and a
                successor must not retry it — so both settle terminally.

                Any other exception is genuinely unknown: whether the effect
                landed is precisely what nobody can say, so the record stays at
                its unknown phase, admission blocks, and the next invocation's
                recovery owns it. Settling that terminally would be a claim we
                cannot make. -}
                attempted <- try (runStep step execution)
                let observation = case attempted of
                        Right observed -> observed
                        Left (SafetyRefusal reason) -> StepRefused (Text.pack reason)
                settled <-
                    inEntry $ \s ->
                        acknowledgeOutcome
                            s
                            sess
                            gate
                            (settledPhaseFor observation)
                            observation
                            afterPrepare
                case attempted of
                    -- Settled first, then re-thrown, so the caller's existing
                    -- refusal handling is unchanged and the record is correct
                    -- whichever way the caller unwinds.
                    Left refusal -> throwIO refusal
                    Right _ -> pure (fmap (\advance -> withOperationAdvance advance (,)) settled)

    renderRow step observation =
        renderStep step ++ ": " ++ Text.unpack (observationDetail observation)

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
    descendInto epoch sess fence permit next =
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
                    Right (ExitSuccess, out, _) ->
                        putStr out >> runPostHandoff epoch sess fence permit
                    -- Surface the nested frame's captured stdout even on failure (it holds
                    -- the frame's step-by-step progress); the stderr becomes the error.
                    Right (_, out, err) -> putStr out >> pure (Left err)
                    Left err -> pure (Left err)

    {- Run this frame's post-handoff nodes, then close the session.

    The close refuses while any operation is unsettled, which is exactly right:
    a chain that stopped early leaves registered-but-unsettled nodes, so its
    session stays Open and the next invocation's sweep resolves it rather than
    this one pretending it finished. -}
    runPostHandoff epoch sess fence permit = do
        ran <- runPlanSteps epoch sess fence permit (postHandoffStepsForFrame current plan)
        case ran of
            Left err -> pure (Left err)
            Right afterPost -> do
                closed <- inEntry (\s -> closeOperationSession s sess afterPost)
                pure (() <$ closed)
