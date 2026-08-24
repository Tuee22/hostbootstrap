{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

{- | The exact current-frame chain interpreter.

The interpreter consumes the non-empty 'HostBootstrap.ProjectPlan.forward'
projection of one admitted project plan.  Its command authority and lifecycle
cursor share the plan, frame, broker, verb, and phase indices, so the operation
session cannot silently allocate a second broker generation or run a node from
another admission.  Descent is read from that plan's 'DerivedTopology'; it is
not reconstructed from steps or accepted as a second caller-supplied graph.
-}
module HostBootstrap.Chain (
    renderChain,
    nextFrameAfter,
    handoffDispatch,
    runChainFromFrame,
    runChainFromFrameWithDescent,
    runChainFromFrameWithDescentFailure,
)
where

import Control.Exception.Safe (throwIO, tryAny)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (intercalate, partition)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Authority (
    CommandAuthority,
    ExecutePhase,
    VerbUp,
    brokerEpochWord,
    commandAuthorityEpoch,
    commandAuthorityFrame,
    commandAuthorityInvocation,
    commandAuthorityMatchesStore,
    commandAuthorityPhase,
    commandAuthorityVerb,
    invocationIdText,
    lifecyclePhaseName,
    projectVerbName,
 )
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Execution.Internal (
    ResourceCarrier,
    carriedResourceKey,
    carriedResourceSettlement,
    newResourceCarrier,
    newStepRuntime,
    openStepRuntimeGate,
    readCarriedResources,
    setStepRuntimeOwnGate,
    stepRuntimeCarrier,
    stepRuntimeOpenGates,
    stepRuntimeTakenGates,
 )
import HostBootstrap.Lifecycle.Mode (
    LifecycleCursor,
    lifecycleCursorFrame,
    lifecycleCursorMatchesCommandAuthority,
    lifecycleCursorPhase,
    lifecycleCursorVerb,
    validateCurrentLifecycleCursor,
 )
import HostBootstrap.Lifecycle.ResourceRecord (
    resourceRecordKeyKernel,
    verifyReleasedResourceSuccessorKernel,
 )
import HostBootstrap.Lifecycle.Session (
    FenceEpoch,
    IntentOrigin (NoHistory),
    OperationSession,
    ProjectPermit,
    SessionError (..),
    acknowledgeOutcome,
    closeOperationSession,
    establishInitialFence,
    openOperationSession,
    openProjectJournal,
    preparedGateOperation,
    recoverAbandonedSessions,
    registerOperationIntent,
    sessionErrorMessage,
    withOperationAdvance,
    withPreparedGate,
    withStepPreparedGate,
 )
import HostBootstrap.Lift (
    LiftContext,
    LiftDispatch,
    SelfRef,
    foldLift,
    liftStdin,
    liftSubcommandWithStdin,
 )
import HostBootstrap.ProjectPlan (
    DerivedTopology,
    PlannedStep,
    PlannedStepObservation,
    ProjectPlan,
    forward,
    operationKeyText,
    plannedStepFrameId,
    plannedStepLabel,
    plannedStepObservationDetail,
    plannedStepObservationSucceeded,
    plannedStepOperationKey,
    plannedStepProjectedOperationKeys,
    plannedStepRunsAfterHandoff,
    renderSnapshot,
    runPlannedStep,
    stablePlanSnapshotDigest,
    topology,
    topologyContainsFrame,
    topologyDescentFrom,
    topologyFrameOrder,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    ProtectedStore,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    protectedErrorMessage,
    readProtectedRecord,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile (stepExecutionFor)
import System.Exit (ExitCode (ExitSuccess))

{- | Render the exact non-empty forward projection in its admitted order.

This is the same projection from which 'runChainFromFrame' selects its
current-frame segment.  It never opens another plan or reads the hidden raw
step representation.
-}
renderChain ::
    ProjectPlan scope specDigest planId configId cfg ->
    String
renderChain plan =
    unlines
        ( zipWith
            (\number planned -> show number ++ ". " ++ renderPlannedStep planned)
            [1 :: Int ..]
            (NonEmpty.toList (orderedProjection plan))
        )

{- | The exact child frame and lift context derived for a current frame.

The topology itself carries the plan indices.  A missing result means either
the innermost frame or a descriptive frame absent from that topology; the
effectful entry distinguishes those cases before interpreting anything.
-}
nextFrameAfter ::
    DerivedTopology scope planId ->
    Text ->
    Maybe (Text, LiftContext)
nextFrameAfter = topologyDescentFrom

-- | The pure host dispatch for the recursive handoff.
handoffDispatch :: SelfRef -> LiftContext -> LiftDispatch
handoffDispatch self context = foldLift self context handoffArgv

handoffArgv :: [String]
handoffArgv = ["project", "up"]

-- | Durable phase published before a node effect is attempted.
unknownStepPhase :: Text
unknownStepPhase = "EffectOutcomeUnknown"

-- | Durable settled phase selected from the node's definite observation.
settledPhaseFor :: PlannedStepObservation scope planId configId -> Text
settledPhaseFor observation
    | plannedStepObservationSucceeded observation = "Committed"
    | otherwise = "StepObservedTerminal"

{- | Interpret one exact current-frame projection.

The authority and cursor are intentionally fixed to @ProjectUp@'s execute
phase.  Their shared nominal indices establish the plan, frame, broker, verb,
and phase relation; their retained terms are also compared before any durable
transition.  The authority's broker epoch and invocation identity drive the
operation session, so this path allocates neither a second broker nor a second
command identity.
-}
runChainFromFrame ::
    forall scope specDigest planId configId cfg frame brokerGeneration.
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan scope specDigest planId configId cfg ->
    CommandAuthority scope planId frame brokerGeneration VerbUp ExecutePhase ->
    LifecycleCursor scope planId frame brokerGeneration VerbUp ExecutePhase ->
    IO (Either String ())
runChainFromFrame cfg self store plan authority cursor =
    runChainFromFrameWithDescent cfg self store plan authority cursor legacyDescent
  where
    legacyDescent _carrier _parent _child descent = do
        result <- liftSubcommandWithStdin cfg self descent handoffArgv (liftStdin descent)
        case result of
            Right (ExitSuccess, out, _) -> putStr out >> pure (Right ())
            Right (_, out, err) -> putStr out >> pure (Left err)
            Left failure -> pure (Left failure)

{- | Interpret a current frame while delegating its one admitted descent.

The callback receives only the exact parent/child frame names and plan-owned
lift context already selected from this plan.  The root coordinator uses this
seam to replace the ordinary command invocation with its authenticated process
exchange; all local preparation and settlement remain in this interpreter.
-}
runChainFromFrameWithDescent ::
    forall scope specDigest planId configId cfg frame brokerGeneration.
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan scope specDigest planId configId cfg ->
    CommandAuthority scope planId frame brokerGeneration VerbUp ExecutePhase ->
    LifecycleCursor scope planId frame brokerGeneration VerbUp ExecutePhase ->
    (ResourceCarrier scope planId -> Text -> Text -> LiftContext -> IO (Either String ())) ->
    IO (Either String ())
runChainFromFrameWithDescent cfg _self store plan authority cursor runDescent =
    runChainFromFrameWithDescentObserved
        cfg
        store
        plan
        authority
        cursor
        runDescent
        (const (pure ()))

{- | Retain the exact operation prefix whose durable Prepared gates were
published before a failed forward interpretation. The two operation lists are
identical at this boundary: none has yet been admitted for unwind settlement.
-}
runChainFromFrameWithDescentFailure ::
    forall scope specDigest planId configId cfg frame brokerGeneration.
    HostConfig ->
    SelfRef ->
    ProtectedStore ->
    ProjectPlan scope specDigest planId configId cfg ->
    CommandAuthority scope planId frame brokerGeneration VerbUp ExecutePhase ->
    LifecycleCursor scope planId frame brokerGeneration VerbUp ExecutePhase ->
    (ResourceCarrier scope planId -> Text -> Text -> LiftContext -> IO (Either String ())) ->
    IO (Either (String, [Text], [Text]) ())
runChainFromFrameWithDescentFailure cfg _self store plan authority cursor runDescent = do
    reachedRef <- newIORef []
    outcome <-
        runChainFromFrameWithDescentObserved
            cfg
            store
            plan
            authority
            cursor
            runDescent
            (modifyIORef' reachedRef . appendNew)
    case outcome of
        Right () -> pure (Right ())
        Left failure -> do
            reached <- readIORef reachedRef
            pure (Left (failure, reached, reached))
  where
    appendNew observed retained = retained <> filter (`notElem` retained) observed

runChainFromFrameWithDescentObserved ::
    forall scope specDigest planId configId cfg frame brokerGeneration.
    HostConfig ->
    ProtectedStore ->
    ProjectPlan scope specDigest planId configId cfg ->
    CommandAuthority scope planId frame brokerGeneration VerbUp ExecutePhase ->
    LifecycleCursor scope planId frame brokerGeneration VerbUp ExecutePhase ->
    (ResourceCarrier scope planId -> Text -> Text -> LiftContext -> IO (Either String ())) ->
    ([Text] -> IO ()) ->
    IO (Either String ())
runChainFromFrameWithDescentObserved cfg store plan authority cursor runDescent onReached =
    case admittedCurrentFrame of
        Left failure -> pure (Left failure)
        Right currentNodes -> do
            opened <- openChainJournal
            case opened of
                Left failure -> pure (Left failure)
                Right (session, fence, permit) -> do
                    carrier <- newResourceCarrier
                    interpret currentNodes carrier session fence permit
  where
    current = commandAuthorityFrame authority
    derivedTopology = topology plan
    planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
    commandEpoch = commandAuthorityEpoch authority
    invocationIdentity = invocationIdText (commandAuthorityInvocation authority)
    sessionIdentity =
        Text.concat
            [ "chain-"
            , Text.pack (show (brokerEpochWord commandEpoch))
            , "-"
            , Text.take 12 (Text.drop 8 invocationIdentity)
            ]

    admittedCurrentFrame = do
        validateEvidence
        currentFrameProjection plan current

    validateEvidence
        | not (commandAuthorityMatchesStore authority store) =
            Left "project up: command authority does not belong to the supplied protected store"
        | not (lifecycleCursorMatchesCommandAuthority authority cursor) =
            Left "project up: command authority and lifecycle cursor origins do not match"
        | current /= lifecycleCursorFrame cursor =
            Left
                ( "project up: command authority frame "
                    ++ Text.unpack current
                    ++ " does not match lifecycle cursor frame "
                    ++ Text.unpack (lifecycleCursorFrame cursor)
                )
        | projectVerbName (commandAuthorityVerb authority)
            /= projectVerbName (lifecycleCursorVerb cursor) =
            Left "project up: command authority and lifecycle cursor verbs do not match"
        | lifecyclePhaseName (commandAuthorityPhase authority)
            /= lifecyclePhaseName (lifecycleCursorPhase cursor) =
            Left "project up: command authority and lifecycle cursor phases do not match"
        | not (topologyContainsFrame derivedTopology current) =
            Left
                ( "project up: current frame "
                    ++ Text.unpack current
                    ++ " is not a frame of the admitted plan (frames: "
                    ++ intercalate
                        ", "
                        (map (Text.unpack . fst) (NonEmpty.toList (topologyFrameOrder derivedTopology)))
                    ++ ")"
                )
        | otherwise = Right ()

    openChainJournal ::
        IO
            ( Either
                String
                ( OperationSession scope planId
                , FenceEpoch scope planId
                , ProjectPermit scope planId
                )
            )
    openChainJournal = inEntry $ \protected -> do
        swept <- recoverAbandonedSessions protected planDigest
        case swept of
            Left failure -> pure (Left failure)
            Right _ -> do
                journal <- openProjectJournal protected planDigest
                case journal of
                    Left failure -> pure (Left failure)
                    Right initial -> do
                        started <-
                            openOperationSession
                                protected
                                commandEpoch
                                planDigest
                                sessionIdentity
                                initial
                        case started of
                            Left failure -> pure (Left failure)
                            Right (session, afterOpen) -> do
                                settled <- establishInitialFence protected planDigest 1
                                case settled of
                                    Left failure -> pure (Left failure)
                                    Right fence -> pure (Right (session, fence, afterOpen))

    registerAll _ _ permit [] = pure (Right permit)
    registerAll protected session permit (operation : rest) = do
        registered <- registerOperationIntent protected session operation NoHistory permit
        case registered of
            Left failure -> pure (Left failure)
            Right next -> registerAll protected session next rest

    interpret currentNodes carrier session fence permit = do
        let (preHandoff, postHandoff) =
                partition (not . plannedStepRunsAfterHandoff) (NonEmpty.toList currentNodes)
        preRan <- runPlanSteps carrier session fence permit preHandoff
        case preRan of
            Left failure -> pure (Left failure)
            Right afterPre ->
                case nextFrameAfter derivedTopology current of
                    Nothing ->
                        runPostHandoff carrier session fence afterPre postHandoff
                    Just (childFrame, descent) ->
                        descendInto
                            carrier
                            session
                            fence
                            afterPre
                            postHandoff
                            childFrame
                            descent

    runPlanSteps _ _ _ permit [] = pure (Right permit)
    runPlanSteps carrier session fence permit (planned : rest) = do
        runtime <- newStepRuntime carrier
        let execution = stepExecutionFor plan cfg runtime planned
        ran <- runNode session fence permit planned execution runtime
        case ran of
            Left failure -> pure (Left failure)
            Right (observation, afterNode)
                | plannedStepObservationSucceeded observation ->
                    runPlanSteps carrier session fence afterNode rest
                | otherwise -> do
                    closed <- closeAfterNode session afterNode
                    case closed of
                        Left failure -> pure (Left failure)
                        Right _ -> do
                            putStrLn ("  " ++ renderRow planned observation)
                            pure (Left ("project up: " ++ renderRow planned observation))

    runNode session fence permit planned execution runtime = do
        prepared <-
            inEntry $ \protected -> do
                registered <-
                    registerAll
                        protected
                        session
                        permit
                        (nodeOperationKeys planned)
                case registered of
                    Left failure -> pure (Left failure)
                    Right afterRegistration ->
                        openProjections
                            protected
                            session
                            commandEpoch
                            fence
                            runtime
                            afterRegistration
                            (projectedKeysOf planned)
                            ( \afterProjections ->
                                withStepPreparedGate
                                    protected
                                    session
                                    commandEpoch
                                    fence
                                    execution
                                    unknownStepPhase
                                    afterProjections
                                    ( \gate next -> do
                                        setStepRuntimeOwnGate runtime gate
                                        pure (Right (gate, next))
                                    )
                            )
        case prepared of
            Left failure -> pure (Left failure)
            Right (gate, afterPrepare) -> do
                onReached (nodeOperationKeys planned)
                attempted <- tryAny (runPlannedStep planned execution)
                case attempted of
                    Left exception -> do
                        -- A synchronous callback failure is a definite terminal
                        -- observation by this still-live interpreter.  Settle the
                        -- prepared gates before propagating the original exception;
                        -- otherwise an ordinary command failure is indistinguishable
                        -- from a process crash and strands EffectOutcomeUnknown.
                        settled <- settleNode True runtime session gate afterPrepare "StepObservedTerminal"
                        case settled of
                            Left failure -> pure (Left failure)
                            Right advance ->
                                withOperationAdvance advance $ \_ afterNode -> do
                                    closed <- closeAfterNode session afterNode
                                    case closed of
                                        Left failure -> pure (Left failure)
                                        Right _ -> throwIO exception
                    Right observation -> do
                        settled <-
                            settleNode
                                False
                                runtime
                                session
                                gate
                                afterPrepare
                                (settledPhaseFor observation)
                        pure $ case settled of
                            Left failure -> Left failure
                            Right advance ->
                                Right (withOperationAdvance advance (\() afterNode -> (observation, afterNode)))

    settleNode includeOpen runtime session gate afterPrepare phase =
        inEntry $ \protected -> do
            taken <- stepRuntimeTakenGates runtime
            available <- if includeOpen then stepRuntimeOpenGates runtime else pure []
            settleProjections
                protected
                session
                runtime
                phase
                (taken <> available)
                afterPrepare
                ( \afterTaken ->
                    persistThenAcknowledge
                        protected
                        session
                        runtime
                        gate
                        phase
                        ()
                        afterTaken
                )

    closeAfterNode session permit =
        inEntry (\protected -> closeOperationSession protected session permit)

    openProjections _ _ _ _ _ permit [] use = use permit
    openProjections protected session epoch fence runtime permit (operation : rest) use =
        withPreparedGate
            protected
            session
            epoch
            fence
            operation
            unknownStepPhase
            permit
            ( \gate next -> do
                openStepRuntimeGate runtime gate
                openProjections protected session epoch fence runtime next rest use
            )

    settleProjections _ _ _ _ [] permit use = use permit
    settleProjections protected session runtime phase (projected : rest) permit use = do
        acknowledged <-
            persistThenAcknowledge
                protected
                session
                runtime
                projected
                phase
                ()
                permit
        case acknowledged of
            Left failure -> pure (Left failure)
            Right advance ->
                withOperationAdvance
                    advance
                    (\() next -> settleProjections protected session runtime phase rest next use)

    persistThenAcknowledge protected session runtime gate phase result permit = do
        persisted <- persistCarriedSettlement protected runtime (preparedGateOperation gate)
        case persisted of
            Left failure -> pure (Left failure)
            Right () -> acknowledgeOutcome protected session gate phase result permit

    persistCarriedSettlement protected runtime operation = do
        carried <- readCarriedResources (stepRuntimeCarrier runtime)
        case filter ((== operation) . carriedResourceKey) carried of
            [] -> pure (Right ())
            [resource] -> case carriedResourceSettlement resource of
                Nothing -> pure (Left (SessionPreparedGateMismatch "managed resource has no durable settlement"))
                Just (frame, expected, bytes) -> writeStableMember protected frame operation expected bytes
            _ -> pure (Left (SessionPreparedGateMismatch "duplicate carried resource settlement"))

    writeStableMember protected frame resource expected bytes =
        case resourceRecordKey planDigest frame resource of
            Left failure -> pure (Left failure)
            Right key -> do
                observed <- readProtectedRecord protected key
                case observed of
                    Left failure -> pure (Left (SessionStoreFailure failure))
                    Right Nothing -> case expected of
                        Just _ -> pure (Left (SessionPreparedGateMismatch "missing resource settlement predecessor"))
                        Nothing -> do
                            written <- compareAndSwapProtectedRecord protected key ExpectAbsent bytes
                            pure (either (Left . SessionStoreFailure) (const (Right ())) written)
                    Right (Just record)
                        | protectedRecordBytes record == bytes -> pure (Right ())
                        | Just (protectedRecordBytes record) == expected -> do
                            written <-
                                compareAndSwapProtectedRecord
                                    protected
                                    key
                                    (ExpectVersion (protectedRecordVersion record))
                                    bytes
                            pure (either (Left . SessionStoreFailure) (const (Right ())) written)
                        | Nothing <- expected
                        , Right () <- verifyReleasedResourceSuccessorKernel (protectedRecordBytes record) bytes -> do
                            written <-
                                compareAndSwapProtectedRecord
                                    protected
                                    key
                                    (ExpectVersion (protectedRecordVersion record))
                                    bytes
                            pure (either (Left . SessionStoreFailure) (const (Right ())) written)
                        | otherwise -> pure (Left (SessionPreparedGateMismatch "conflicting resource settlement"))

    resourceRecordKey digest frame resource = do
        raw <- either (Left . SessionPreparedGateMismatch) Right (resourceRecordKeyKernel digest frame resource)
        either (Left . SessionStoreFailure) Right (mkRecordKey raw)

    descendInto carrier session fence permit postHandoff childFrame descent = do
        result <- runDescent carrier current childFrame descent
        case result of
            Right () -> runPostHandoff carrier session fence permit postHandoff
            Left failure -> pure (Left failure)

    runPostHandoff carrier session fence permit postHandoff = do
        ran <- runPlanSteps carrier session fence permit postHandoff
        case ran of
            Left failure -> pure (Left failure)
            Right afterPost -> do
                closed <- inEntry (\protected -> closeOperationSession protected session afterPost)
                pure (() <$ closed)

    inEntry ::
        (forall protected. ProtectedSession protected -> IO (Either SessionError result)) ->
        IO (Either String result)
    inEntry action = do
        outcome <-
            withProtectedEntry store $ \protected ->
                fmap Right $ do
                    currentCursor <- validateCurrentLifecycleCursor protected cursor
                    case currentCursor of
                        Left failure -> pure (Left failure)
                        Right () -> action protected
        pure $ case outcome of
            Left storeFailure -> Left (Text.unpack (protectedErrorMessage storeFailure))
            Right (Left failure) -> Left (sessionErrorMessage failure)
            Right (Right value) -> Right value

orderedProjection ::
    ProjectPlan scope specDigest planId configId cfg ->
    NonEmpty (PlannedStep scope planId configId (cfg scope))
orderedProjection = forward

currentFrameProjection ::
    ProjectPlan scope specDigest planId configId cfg ->
    Text ->
    Either String (NonEmpty (PlannedStep scope planId configId (cfg scope)))
currentFrameProjection plan current =
    case NonEmpty.nonEmpty
        ( filter
            ((== current) . plannedStepFrameId)
            (NonEmpty.toList (orderedProjection plan))
        ) of
        Nothing ->
            Left
                ( "project up: admitted frame "
                    ++ Text.unpack current
                    ++ " has no forward nodes"
                )
        Just planned -> Right planned

nodeOperationKeys :: PlannedStep scope planId configId config -> [Text]
nodeOperationKeys planned =
    Text.pack (operationKeyText (plannedStepOperationKey planned))
        : projectedKeysOf planned

projectedKeysOf :: PlannedStep scope planId configId config -> [Text]
projectedKeysOf =
    map (Text.pack . operationKeyText) . plannedStepProjectedOperationKeys

renderRow ::
    PlannedStep scope planId configId config ->
    PlannedStepObservation scope planId configId ->
    String
renderRow planned observation =
    renderPlannedStep planned
        ++ ": "
        ++ Text.unpack (plannedStepObservationDetail observation)

renderPlannedStep :: PlannedStep scope planId configId config -> String
renderPlannedStep planned =
    "["
        ++ Text.unpack (plannedStepFrameId planned)
        ++ "] "
        ++ operationKind planned
        ++ " — "
        ++ Text.unpack (plannedStepLabel planned)

operationKind :: PlannedStep scope planId configId config -> String
operationKind planned =
    let rendered = operationKeyText (plannedStepOperationKey planned)
     in case break (== ':') rendered of
            (_, ':' : kind) -> kind
            _ -> rendered
