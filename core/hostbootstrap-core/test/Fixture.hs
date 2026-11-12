{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoMonoLocalBinds #-}

{- | A core-internal project-config instance used by the core test suite.

The core is generic over a project's config type (the 'ProjectCfg' class); the
concrete config record lives in a consumer (the demo). The core tests need a
concrete 'ProjectCfg' to exercise the generic command/CLI machinery and the
generic sibling loader, so this module supplies a faithful in-test instance
(the same four-field shape the demo's @ProjectConfig@ has, so its reflected
Dhall schema and decode round-trips are equivalent coverage of what moved out
of core).
-}
module Fixture (
    FixtureProject,
    SecretFixtureProject,
    ProjectConfig (..),
    SecretProjectConfig (..),
    DeployConfig (..),
    Resources (..),
    TestConfig (..),
    defaultProjectConfig,
    defaultTestConfig,
    renderProjectConfig,
    decodeProjectConfigText,
    decodeProjectConfigFile,
    renderTestConfig,
    decodeTestConfigText,
    projectConfigSchemaText,
    projectConfigCodec,
    testConfigCodec,
    refusingForwardChildPlan,
    projectingForwardChildPlan,
    deriveProjectConfigForKind,
    projectConfigForRole,
    initArgsFor,
    projectInit,
    fixtureExecutableName,
    withFixtureInstalledProject,
    withFixtureProjectRoot,
    withFixtureProjectPlan,
    withFixtureProjectPlanPair,
    withFixtureProjectPlanConfigPair,
    withFixtureRootChainEvidence,
    withFixtureRootChainPasses,
    withFixtureRootChainEvidenceVariants,
    canonicalSnapshotFromProjectPlan,
    withFixtureCanonicalSnapshotVariants,
    withFixtureProjectPlanConfig,
    withFixtureProjectPlanContext,
    withFixtureProjectPlanRoot,
    withFixtureHarnessProjectPlan,
    withFixtureHarnessProjectPlanConfig,
    withFixtureHarnessAuthority,
    newFakeTool,
    newExhaustingFakeTool,
    newRecordingFakeTool,
)
where

import Control.Monad (foldM, forM_, unless, when)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall)
import Expect (expectRight)
import GHC.Generics (Generic)
import HostBootstrap.Authority (InstalledProjectIdentity, VerbUp)
import qualified HostBootstrap.Authority as Authority
import qualified HostBootstrap.Authority.ProjectPlan as ProjectAuthority
import HostBootstrap.Cluster.Budget (BudgetCfg (..))
import HostBootstrap.Config.Class (
    ExistingOutputPolicy (..),
    InitArgs (..),
    ProjectCfg (..),
    ProjectCodec,
    TestCfg (..),
    withMappedProjectCodec,
    withProjectCodec,
 )
import HostBootstrap.Config.Schema (withValidatedConfig)
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Context (BinaryContext)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (
    CodecWitness,
    autoCodecWitness,
    codecSchemaText,
    decodeFile,
    decodeText,
    renderHoistedValue,
    renderValue,
    requireCodecWitness,
 )
import HostBootstrap.Harness (VariantId, mkTestMatrix, mkVariantId, runWithOwnedRun, variantDraft)
import HostBootstrap.Harness.Ownership (
    protectedProjectRunOwnership,
    withOwnedHarnessRoot,
 )
import qualified HostBootstrap.Lifecycle.Context as LifecycleContext
import HostBootstrap.Lifecycle.Mode (
    AcquisitionJournal,
    LifecycleCursor,
    LifecycleProfile,
    ProductionRoot,
    ProductionInvocationClose (..),
    completeProductionInvocation,
    closeCompletedProductionInvocation,
    mkInvocationCloseKey,
    harnessActiveMode,
    harnessRootAuthority,
    harnessRootHarnessAuthority,
    harnessRootModeLease,
    harnessRootRunId,
    harnessRootUnboundLease,
    lifecycleCursorFrame,
    productionActiveMode,
    productionRootAuthority,
    productionRootModeLease,
    productionRootUnboundLease,
    withHarnessLifecycleProfile,
    withAcquisitionJournal,
    withExecuteLifecycleCursor,
    withLifecycleCursor,
    withProductionLifecycleProfile,
    withProductionRoot,
 )
import HostBootstrap.Lifecycle.Session (verifyAllSessionsClosed)
import qualified HostBootstrap.Lifecycle.Snapshot.Core as SnapshotCore (StablePlanSnapshot (StablePlanSnapshot))
import HostBootstrap.Lift.Context (LiftContext, localContext)
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    planDraftsFromValidatedBuilder,
    renderSnapshot,
    stablePlanSnapshotDigest,
    topology,
    topologyContainsFrame,
 )
import HostBootstrap.ProjectPlan.Construct (withProjectPlan)
import HostBootstrap.ProjectPlan.Frame (ProjectFrame, projectFrameId, withCurrentFrame)
import HostBootstrap.ProjectPlan.Snapshot (withPersistedPlanSnapshot)
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import HostBootstrap.Protected (ProtectedStore, openProtectedStore, withProtectedEntry)
import HostBootstrap.Reconcile (CanonicalPlanSnapshot)
import HostBootstrap.Step (
    Step,
    StepFrame (StepFrame),
    StepObservation (StepChanged),
    StepPlan,
    contextInitStep,
    descendsVia,
    ensureStep,
    mkStepPlan,
 )
import Numeric.Natural (Natural)
#if !defined(mingw32_HOST_OS)
import System.Directory (getPermissions, setOwnerExecutable, setPermissions)
#endif
import System.Environment (getExecutablePath)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Unsafe.Coerce (unsafeCoerce)

{- | Acquire a real protected generative Harness root for authority-sensitive
tests. The helper fails if acquisition or finalization does not settle; it never
mints authority from a caller-selected run name.
-}
withFixtureHarnessAuthority ::
    forall result.
    ( forall projectId runId.
      Authority.InstalledProjectIdentity projectId ->
      V.HarnessAuthority projectId runId ->
      IO result
    ) ->
    IO result
withFixtureHarnessAuthority use =
    withFixtureInstalledProject $ \project ->
        withSystemTempDirectory "hostbootstrap-harness-authority" $ \root -> do
            rooted <-
                withCanonicalProjectRoot root root $ \canonicalRoot ->
                    runWithOwnedRun
                        ( protectedProjectRunOwnership
                            project
                            canonicalRoot
                            root
                            (root </> ".test_data")
                        )
                        ( \owned ->
                            withOwnedHarnessRoot owned $ \_store _project harnessRoot _closeControl ->
                                use project (harnessRootHarnessAuthority harnessRoot)
                        )
            outcome <- either (ioError . userError . show) pure rooted
            case outcome of
                Left reason -> ioError (userError reason)
                Right (result, Nothing) -> pure result
                Right (_, Just failure) ->
                    ioError (userError ("harness authority cleanup failed: " ++ show failure))

-- | The executable-verified name used by the core test binary.
fixtureExecutableName :: IO Text
fixtureExecutableName = Authority.normalizeExecutableIdentity <$> getExecutablePath

{- | Admit the actual test executable identity without allowing its generative
@projectId@ to escape the continuation.
-}
withFixtureInstalledProject ::
    (forall projectId. Authority.InstalledProjectIdentity projectId -> IO result) ->
    IO result
withFixtureInstalledProject use = do
    name <- fixtureExecutableName
    admitted <- Authority.withInstalledProjectIdentity name use
    either
        (ioError . userError . T.unpack . Authority.authorityErrorMessage)
        pure
        admitted

{- | Admit one real Production project plan for projection/reconciliation
tests while keeping every generated identity inside the callback.
-}
withFixtureProjectPlan ::
    StepPlan ->
    ( forall projectId specDigest planId configId.
      ProjectPlan
        (V.Production projectId)
        specDigest
        planId
        configId
        ProjectConfig ->
      IO result
    ) ->
    IO result
withFixtureProjectPlan stepPlan use =
    withFixtureProjectPlanContext id stepPlan (\plan _context -> use plan)

{- | Admit one real root command and Execute cursor before a direct Chain call.

The protected store occupies the public lifecycle-context path. Every protocol
result is forced while its root, profile and frame evidence remain in scope.
-}
withFixtureRootChainEvidence ::
    (ProtectedStore -> StepFrame -> StepPlan) ->
    ( forall projectId specDigest planId configId frame brokerGeneration.
      ProtectedStore ->
      ProjectPlan (V.Production projectId) specDigest planId configId ProjectConfig ->
      Authority.CommandAuthority (V.Production projectId) planId frame brokerGeneration VerbUp Authority.ExecutePhase ->
      LifecycleCursor (V.Production projectId) planId frame brokerGeneration VerbUp Authority.ExecutePhase ->
      IO result
    ) ->
    IO result
withFixtureRootChainEvidence build use =
    withFixtureRootChainEvidenceScope build $ \store _root _profile _codec _value plan _journal authority cursor ->
        use store plan authority cursor

withFixtureRootChainEvidenceScope ::
    (ProtectedStore -> StepFrame -> StepPlan) ->
    ( forall projectId rootId specDigest planId configId frame brokerGeneration.
      ProtectedStore ->
      CanonicalProjectRoot (V.Production projectId) rootId ->
      LifecycleProfile (V.Production projectId) ->
      ProjectCodec (V.Production projectId) specDigest ProjectConfig ->
      ProjectConfig (V.Production projectId) ->
      ProjectPlan (V.Production projectId) specDigest planId configId ProjectConfig ->
      AcquisitionJournal (V.Production projectId) planId brokerGeneration ->
      Authority.CommandAuthority (V.Production projectId) planId frame brokerGeneration VerbUp Authority.ExecutePhase ->
      LifecycleCursor (V.Production projectId) planId frame brokerGeneration VerbUp Authority.ExecutePhase ->
      IO result
    ) ->
    IO result
withFixtureRootChainEvidenceScope build use =
    withFixtureInstalledProject $ \project ->
        withSystemTempDirectory "hostbootstrap-fixture-root-chain" $ \directory -> do
            rooted <- withCanonicalProjectRoot (directory </> "fixture.dhall") directory $ \root -> do
                let rootPath = canonicalProjectRootPath root
                    projectName = Authority.installedProjectName project
                    value = defaultProjectConfig projectName (T.pack rootPath) Context.HostOrchestrator
                    exactContext = value.context
                    frameId = Context.currentFrame exactContext
                store <- expectRight =<< openProtectedStore (rootPath </> ".hostbootstrap" </> "authority" </> T.unpack projectName)
                opened <- withProductionRoot store project Authority.ProjectUp $ \production -> do
                    let rootAuthority = productionRootAuthority production
                        unbound = productionRootUnboundLease production
                        graph = build store (StepFrame (T.unpack frameId) "Host orchestrator")
                    profileAction <- expectRight =<< withProductionLifecycleProfile
                        (Authority.rootScopeAuthority rootAuthority)
                        (productionActiveMode (productionRootModeLease production))
                        unbound
                        ( \profile -> withProductionProjectCodec @ProjectConfig $ \codec -> do
                            validated <- withValidatedConfig codec value $ \_wire config -> do
                                drafts <- expectRight (planDraftsFromValidatedBuilder root config (\_ _ -> Right graph))
                                planAction <- expectRight $ withProjectPlan profile root config drafts $ \plan -> do
                                    persisted <- withPersistedPlanSnapshot rootAuthority unbound plan $ \verified bound binding lease _ -> do
                                        contextual <- LifecycleContext.withValidatedLifecycleContext root store plan exactContext $ \lifecycleContext -> do
                                            frameAction <- expectRight $ withCurrentFrame plan exactContext $ \_ frame _ -> do
                                                unless (projectFrameId frame == frameId) (fail "the public root frame changed its semantic identity")
                                                journaled <- withAcquisitionJournal rootAuthority lease bound binding plan $ \journal -> do
                                                    cursored <- withLifecycleCursor journal frame Authority.ProjectUp Authority.Prepare $ \prepareCursor -> do
                                                        executed <- withExecuteLifecycleCursor prepareCursor $ \cursor -> do
                                                            -- The public frame openers have equal checked semantic
                                                            -- identity and fresh skolems. Align only that phantom;
                                                            -- the real root gate revalidates every retained value.
                                                            let aligned = alignFixtureRootCursorFrame cursor
                                                            authority <- expectRight =<< ProjectAuthority.authorizeRootProject
                                                                rootAuthority Authority.ProjectUp verified bound binding lease plan journal aligned lifecycleContext project
                                                            use store root profile codec value plan journal authority aligned
                                                        expectRight executed
                                                    expectRight cursored
                                                expectRight journaled
                                            frameAction
                                        expectRight contextual
                                    expectRight persisted
                                planAction
                            expectRight validated
                        )
                    result <- profileAction
                    pure (Right result)
                expectRight opened
            expectRight rooted

{- | Run fresh, publicly admitted root invocations over one unchanged root.
Each pass must close its independently enumerated sessions and acknowledge its
lease close before the next broker epoch is acquired. No consumed authority or
cursor is replayed.
-}
withFixtureRootChainPasses ::
    Int ->
    (ProtectedStore -> StepFrame -> StepPlan) ->
    ( forall projectId specDigest planId configId frame brokerGeneration.
      ProtectedStore ->
      ProjectPlan (V.Production projectId) specDigest planId configId ProjectConfig ->
      Authority.CommandAuthority (V.Production projectId) planId frame brokerGeneration VerbUp Authority.ExecutePhase ->
      LifecycleCursor (V.Production projectId) planId frame brokerGeneration VerbUp Authority.ExecutePhase ->
      IO ()
    ) ->
    IO ()
withFixtureRootChainPasses passes build use =
    withFixtureInstalledProject $ \project ->
        withSystemTempDirectory "hostbootstrap-fixture-root-chain" $ \directory -> do
            rooted <- withCanonicalProjectRoot (directory </> "fixture.dhall") directory $ \root -> do
                let rootPath = canonicalProjectRootPath root
                    projectName = Authority.installedProjectName project
                    value = defaultProjectConfig projectName (T.pack rootPath) Context.HostOrchestrator
                    exactContext = value.context
                    frameId = Context.currentFrame exactContext
                store <- expectRight =<< openProtectedStore (rootPath </> ".hostbootstrap" </> "authority" </> T.unpack projectName)
                forM_ [1 .. passes] $ \pass -> do
                    opened <- withProductionRoot store project Authority.ProjectUp $ \production -> do
                        let rootAuthority = productionRootAuthority production
                            unbound = productionRootUnboundLease production
                            graph = build store (StepFrame (T.unpack frameId) "Host orchestrator")
                        profileAction <- expectRight =<< withProductionLifecycleProfile
                            (Authority.rootScopeAuthority rootAuthority)
                            (productionActiveMode (productionRootModeLease production))
                            unbound
                            ( \profile -> withProductionProjectCodec @ProjectConfig $ \codec -> do
                                validated <- withValidatedConfig codec value $ \_wire config -> do
                                    drafts <- expectRight (planDraftsFromValidatedBuilder root config (\_ _ -> Right graph))
                                    planAction <- expectRight $ withProjectPlan profile root config drafts $ \plan -> do
                                        persisted <- withPersistedPlanSnapshot rootAuthority unbound plan $ \verified bound binding lease _ -> do
                                            contextual <- LifecycleContext.withValidatedLifecycleContext root store plan exactContext $ \lifecycleContext -> do
                                                frameAction <- expectRight $ withCurrentFrame plan exactContext $ \_ frame _ -> do
                                                    unless (projectFrameId frame == frameId) (fail "the public root frame changed its semantic identity")
                                                    journaled <- withAcquisitionJournal rootAuthority lease bound binding plan $ \journal -> do
                                                        cursored <- withLifecycleCursor journal frame Authority.ProjectUp Authority.Prepare $ \prepareCursor -> do
                                                            executed <- withExecuteLifecycleCursor prepareCursor $ \cursor -> do
                                                                -- The public frame openers have equal checked semantic
                                                                -- identity and fresh skolems. Align only that phantom;
                                                                -- the real root gate revalidates every retained value.
                                                                let aligned = alignFixtureRootCursorFrame cursor
                                                                authority <- expectRight =<< ProjectAuthority.authorizeRootProject
                                                                    rootAuthority Authority.ProjectUp verified bound binding lease plan journal aligned lifecycleContext project
                                                                use store plan authority aligned
                                                                checked <- withProtectedEntry store $ \session ->
                                                                    Right <$> verifyAllSessionsClosed session (stablePlanSnapshotDigest (renderSnapshot plan))
                                                                closed <- expectRight checked >>= expectRight
                                                                completed <- expectRight (completeProductionInvocation lease closed)
                                                                key <- expectRight (mkInvocationCloseKey ("fixture-chain-pass-" <> T.pack (show pass)))
                                                                ended <- withProtectedEntry store $ \session ->
                                                                    Right <$> closeCompletedProductionInvocation session project (productionRootModeLease production) completed key
                                                                closure <- expectRight ended >>= expectRight
                                                                case closure of
                                                                    ProductionInvocationCloseCommitted _ -> pure ()
                                                                    ProductionInvocationCloseUnknown _ -> fail "the fixture invocation close was not acknowledged"
                                                            expectRight executed
                                                        expectRight cursored
                                                    expectRight journaled
                                                frameAction
                                            expectRight contextual
                                        expectRight persisted
                                    planAction
                                expectRight validated
                            )
                        result <- profileAction
                        pure (Right result)
                    expectRight opened
            expectRight rooted

{- | Supply genuine alternative cursor and topology evidence for entry refusals.

The child frame comes from a second admitted plan, but its cursor is opened on
the original acquisition journal. The renamed-root plan is admitted without
replacing the original persisted snapshot or bound lease. Only Chain's negative
controls align the delivered cursor-frame and alternate-plan indices.
-}
withFixtureRootChainEvidenceVariants ::
    (ProtectedStore -> StepFrame -> StepPlan) ->
    ( forall projectId specDigest planId configId frame brokerGeneration childFrame alternatePlanId alternateConfigId.
      ProtectedStore ->
      ProjectPlan (V.Production projectId) specDigest planId configId ProjectConfig ->
      Authority.CommandAuthority (V.Production projectId) planId frame brokerGeneration VerbUp Authority.ExecutePhase ->
      LifecycleCursor (V.Production projectId) planId frame brokerGeneration VerbUp Authority.ExecutePhase ->
      LifecycleCursor (V.Production projectId) planId childFrame brokerGeneration VerbUp Authority.ExecutePhase ->
      ProjectPlan (V.Production projectId) specDigest alternatePlanId alternateConfigId ProjectConfig ->
      IO result
    ) ->
    IO result
withFixtureRootChainEvidenceVariants build use =
    withFixtureRootChainEvidenceScope build $ \store root profile codec value plan journal authority cursor -> do
        let rootContext = value.context
            childContext = Context.deriveTestHarnessContext rootContext (Context.sourceRoot rootContext)
            childValue = value{context = childContext}
            rootFrameId = Context.currentFrame rootContext
            childFrameId = Context.currentFrame childContext
            alternateFrameId = rootFrameId <> "-alternate"
            alternateValue = value{context = renameFixtureRootFrame alternateFrameId rootContext}
            rootStep = contextInitStep "entry policy root" (StepFrame (T.unpack rootFrameId) "Host orchestrator") (const (pure StepChanged))
            alternateGraph = build store (StepFrame (T.unpack alternateFrameId) "Host orchestrator")
        childGraph <- expectRight $ mkStepPlan
            [ descendsVia localContext rootStep
            , ensureStep "entry-policy-child" "entry policy child" (StepFrame (T.unpack childFrameId) "Harness") (const (pure StepChanged))
            ]
        childValidated <- withValidatedConfig codec childValue $ \_ childConfig -> do
            childDrafts <- expectRight (planDraftsFromValidatedBuilder root childConfig (\_ _ -> Right childGraph))
            childPlanAction <- expectRight $ withProjectPlan profile root childConfig childDrafts $ \childPlan -> do
                childFrameAction <- expectRight $ withCurrentFrame childPlan childContext $ \_ childFrame _ -> do
                    unless (projectFrameId childFrame == childFrameId && childFrameId /= rootFrameId) $
                        fail "the genuine child plan did not retain a distinct child frame"
                    -- Only the adversarial frame's plan index changes. Its
                    -- actual semantic frame enters the ORIGINAL journal.
                    childOpened <- withLifecycleCursor journal (alignFixtureFramePlanForRefusal childFrame) Authority.ProjectUp Authority.Prepare $ \childPrepare -> do
                        childExecuted <- withExecuteLifecycleCursor childPrepare $ \childCursor -> do
                            unless (lifecycleCursorFrame childCursor == childFrameId) $
                                fail "the child cursor did not retain the genuine child frame"
                            alternateValidated <- withValidatedConfig codec alternateValue $ \_ alternateConfig -> do
                                alternateDrafts <- expectRight (planDraftsFromValidatedBuilder root alternateConfig (\_ _ -> Right alternateGraph))
                                alternatePlanAction <- expectRight $ withProjectPlan profile root alternateConfig alternateDrafts $ \alternatePlan -> do
                                    alternateFrameAction <- expectRight $ withCurrentFrame alternatePlan alternateValue.context $ \_ alternateFrame _ -> do
                                        unless (projectFrameId alternateFrame == alternateFrameId) $
                                            fail "the alternate plan did not admit its actual configured frame"
                                        when (topologyContainsFrame (topology alternatePlan) rootFrameId) $
                                            fail "the alternate topology still contains the original authority frame"
                                        use store plan authority cursor childCursor alternatePlan
                                    alternateFrameAction
                                alternatePlanAction
                            expectRight alternateValidated
                        expectRight childExecuted
                    expectRight childOpened
                childFrameAction
            childPlanAction
        expectRight childValidated

renameFixtureRootFrame :: Text -> BinaryContext -> BinaryContext
renameFixtureRootFrame target base =
    base
        { Context.topologyFrames = map renameTopologyFrame (Context.topologyFrames base)
        , Context.currentFrame = target
        , Context.runtimeWitnesses = map renameFrameWitness (Context.runtimeWitnesses base)
        }
  where
    renameId value
        | value == Context.currentFrame base = target
        | otherwise = value
    renameTopologyFrame frame =
        frame
            { Context.topologyFrameId = renameId (Context.topologyFrameId frame)
            , Context.topologyParentId = renameId (Context.topologyParentId frame)
            }
    renameFrameWitness witness
        | Context.witnessKind witness == Context.WitnessEnvEquals
            && Context.witnessName witness == "HOSTBOOTSTRAP_CURRENT_FRAME" =
            witness{Context.witnessValue = target}
        | otherwise = witness

alignFixtureFramePlanForRefusal ::
    ProjectFrame scope specDigest sourcePlanId configId frame ->
    ProjectFrame scope specDigest targetPlanId configId frame
alignFixtureFramePlanForRefusal = unsafeCoerce

-- The scope, plan, broker, verb, phase and all retained values remain unchanged.
alignFixtureRootCursorFrame ::
    LifecycleCursor scope planId sourceFrame brokerGeneration verb phase ->
    LifecycleCursor scope planId targetFrame brokerGeneration verb phase
alignFixtureRootCursorFrame = unsafeCoerce

-- | Admit two generative plans under one actual root, profile and validated configuration.
withFixtureProjectPlanPair ::
    StepPlan ->
    StepPlan ->
    ( forall projectId specDigest firstPlanId secondPlanId configId.
      ProjectPlan (V.Production projectId) specDigest firstPlanId configId ProjectConfig ->
      ProjectPlan (V.Production projectId) specDigest secondPlanId configId ProjectConfig ->
      IO result
    ) ->
    IO result
withFixtureProjectPlanPair firstGraph secondGraph use =
    withSystemTempDirectory "hostbootstrap-fixture-project-plan-pair" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
        withFixtureInstalledProject $ \project -> do
            rooted <-
                withCanonicalProjectRoot (directory </> "fixture.dhall") "." $ \root ->
                    withProductionRoot store project Authority.ProjectUp $ \productionRoot -> do
                        opened <-
                            withProductionLifecycleProfile
                                (Authority.rootScopeAuthority (productionRootAuthority productionRoot))
                                (productionActiveMode (productionRootModeLease productionRoot))
                                (productionRootUnboundLease productionRoot)
                                ( \profile ->
                                    withProductionProjectCodec @ProjectConfig $ \codec -> do
                                        let value =
                                                defaultProjectConfig
                                                    (Authority.installedProjectName project)
                                                    (T.pack (canonicalProjectRootPath root))
                                                    Context.HostOrchestrator
                                        validated <-
                                            withValidatedConfig codec value $ \_wire config -> do
                                                firstDrafts <- either (fail . show) pure $
                                                    planDraftsFromValidatedBuilder root config (\_ _ -> Right firstGraph)
                                                secondDrafts <- either (fail . show) pure $
                                                    planDraftsFromValidatedBuilder root config (\_ _ -> Right secondGraph)
                                                firstAction <- either (fail . show) pure $
                                                    withProjectPlan profile root config firstDrafts $ \first -> do
                                                        secondAction <- either (fail . show) pure $
                                                            withProjectPlan profile root config secondDrafts (use first)
                                                        secondAction
                                                firstAction
                                        either fail pure validated
                                )
                        result <- either (fail . show) id opened
                        pure (Right result)
            modeResult <- either (fail . show) pure rooted
            either (fail . show) pure modeResult

-- | Admit two configuration alternatives under one actual root, profile and codec.
withFixtureProjectPlanConfigPair ::
    (forall scope. ProjectConfig scope -> ProjectConfig scope) ->
    (forall scope. ProjectConfig scope -> ProjectConfig scope) ->
    StepPlan ->
    ( forall projectId specDigest firstPlanId firstConfigId secondPlanId secondConfigId.
      ProjectPlan (V.Production projectId) specDigest firstPlanId firstConfigId ProjectConfig ->
      ProjectConfig (V.Production projectId) ->
      ProjectPlan (V.Production projectId) specDigest secondPlanId secondConfigId ProjectConfig ->
      ProjectConfig (V.Production projectId) ->
      IO result
    ) ->
    IO result
withFixtureProjectPlanConfigPair firstTransform secondTransform stepPlan use =
    withSystemTempDirectory "hostbootstrap-fixture-config-pair" $ \directory -> do
        store <- expectRight =<< openProtectedStore (directory </> "protected")
        withFixtureInstalledProject $ \project -> do
            rooted <- withCanonicalProjectRoot (directory </> "fixture.dhall") "." $ \root -> do
                opened <- withProductionRoot store project Authority.ProjectUp $ \production -> do
                    profileAction <- expectRight =<< withProductionLifecycleProfile
                        (Authority.rootScopeAuthority (productionRootAuthority production))
                        (productionActiveMode (productionRootModeLease production))
                        (productionRootUnboundLease production)
                        ( \profile -> withProductionProjectCodec @ProjectConfig $ \codec -> do
                            let base = defaultProjectConfig
                                    (Authority.installedProjectName project)
                                    (T.pack (canonicalProjectRootPath root))
                                    Context.HostOrchestrator
                                firstValue = firstTransform base
                                secondValue = secondTransform base
                            firstValidated <- withValidatedConfig codec firstValue $ \_ firstConfig -> do
                                firstDrafts <- expectRight (planDraftsFromValidatedBuilder root firstConfig (\_ _ -> Right stepPlan))
                                firstAction <- expectRight $ withProjectPlan profile root firstConfig firstDrafts $ \firstPlan -> do
                                    secondValidated <- withValidatedConfig codec secondValue $ \_ secondConfig -> do
                                        secondDrafts <- expectRight (planDraftsFromValidatedBuilder root secondConfig (\_ _ -> Right stepPlan))
                                        secondAction <- expectRight $ withProjectPlan profile root secondConfig secondDrafts $ \secondPlan ->
                                            use firstPlan firstValue secondPlan secondValue
                                        secondAction
                                    expectRight secondValidated
                                firstAction
                            expectRight firstValidated
                        )
                    result <- profileAction
                    pure (Right result)
                expectRight opened
            expectRight rooted

-- | Open only the reporting wrapper of a genuinely admitted project plan.
canonicalSnapshotFromProjectPlan :: ProjectPlan scope specDigest planId configId cfg -> CanonicalPlanSnapshot
canonicalSnapshotFromProjectPlan plan =
    case renderSnapshot plan of
        SnapshotCore.StablePlanSnapshot snapshot -> snapshot

{- | Admit graph and configuration alternatives under one real root, profile,
and codec. The callback receives the base graph, alternate graph, and base graph
with the transformed validated configuration, in that order.
-}
withFixtureCanonicalSnapshotVariants ::
    StepPlan ->
    StepPlan ->
    (forall scope. ProjectConfig scope -> ProjectConfig scope) ->
    (CanonicalPlanSnapshot -> CanonicalPlanSnapshot -> CanonicalPlanSnapshot -> IO result) ->
    IO result
withFixtureCanonicalSnapshotVariants firstGraph secondGraph changeConfig use =
    withSystemTempDirectory "hostbootstrap-fixture-snapshot-variants" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
        withFixtureInstalledProject $ \project -> do
            rooted <-
                withCanonicalProjectRoot (directory </> "fixture.dhall") "." $ \root ->
                    withProductionRoot store project Authority.ProjectUp $ \productionRoot -> do
                        opened <-
                            withProductionLifecycleProfile
                                (Authority.rootScopeAuthority (productionRootAuthority productionRoot))
                                (productionActiveMode (productionRootModeLease productionRoot))
                                (productionRootUnboundLease productionRoot)
                                ( \profile ->
                                    withProductionProjectCodec @ProjectConfig $ \codec -> do
                                        let value =
                                                defaultProjectConfig
                                                    (Authority.installedProjectName project)
                                                    (T.pack (canonicalProjectRootPath root))
                                                    Context.HostOrchestrator
                                            admit config graph = do
                                                drafts <-
                                                    either (fail . show) pure $
                                                        planDraftsFromValidatedBuilder root config (\_ _ -> Right graph)
                                                either (fail . show) pure $
                                                    withProjectPlan profile root config drafts canonicalSnapshotFromProjectPlan
                                        validated <-
                                            withValidatedConfig codec value $ \_wire config -> do
                                                first <- admit config firstGraph
                                                second <- admit config secondGraph
                                                changed <-
                                                    withValidatedConfig codec (changeConfig value) $ \_changedWire changedConfig -> do
                                                        third <- admit changedConfig firstGraph
                                                        use first second third
                                                either fail pure changed
                                        either fail pure validated
                                )
                        result <- either (fail . show) id opened
                        pure (Right result)
            modeResult <- either (fail . show) pure rooted
            either (fail . show) pure modeResult

{- | Admit one real generative Harness project plan.  This follows the same
protected ownership/profile/config/plan path as the command rather than
relabeling a Production fixture.
-}
withFixtureHarnessProjectPlan ::
    StepPlan ->
    ( forall projectId runId specDigest planId configId.
      ProjectPlan
        (V.Harness projectId runId)
        specDigest
        planId
        configId
        ProjectConfig ->
      IO result
    ) ->
    IO result
withFixtureHarnessProjectPlan stepPlan use =
    withFixtureHarnessProjectPlanConfig id stepPlan (\plan _value -> use plan)

withFixtureHarnessProjectPlanConfig ::
    (forall scope. ProjectConfig scope -> ProjectConfig scope) ->
    StepPlan ->
    ( forall projectId runId specDigest planId configId.
      ProjectPlan (V.Harness projectId runId) specDigest planId configId ProjectConfig ->
      ProjectConfig (V.Harness projectId runId) ->
      IO result
    ) ->
    IO result
withFixtureHarnessProjectPlanConfig transform stepPlan use =
    withFixtureInstalledProject $ \project ->
        withSystemTempDirectory "hostbootstrap-fixture-harness-plan" $ \directory -> do
            rooted <-
                withCanonicalProjectRoot directory directory $ \ownershipRoot ->
                    runWithOwnedRun
                        ( protectedProjectRunOwnership
                            project
                            ownershipRoot
                            directory
                            (directory </> ".test_data")
                        )
                        ( \owned ->
                            withOwnedHarnessRoot owned $ \_store _ownedProject harnessRoot _closeControl -> do
                                let authority = harnessRootHarnessAuthority harnessRoot
                                scoped <-
                                    withCanonicalProjectRoot directory directory $ \runRoot -> do
                                        opened <-
                                            withHarnessLifecycleProfile
                                                (Authority.rootScopeAuthority (harnessRootAuthority harnessRoot))
                                                authority
                                                (harnessRootRunId harnessRoot)
                                                (harnessActiveMode (harnessRootModeLease harnessRoot))
                                                (harnessRootUnboundLease harnessRoot)
                                                ( \profile ->
                                                    withHarnessProjectCodec @ProjectConfig
                                                        (V.harnessConfigAuthority authority)
                                                        ( \codec -> do
                                                            let value = transform $
                                                                    defaultProjectConfig
                                                                        (Authority.installedProjectName project)
                                                                        (T.pack (canonicalProjectRootPath runRoot))
                                                                        Context.TestHarness
                                                            validated <-
                                                                withValidatedConfig codec value $ \_wire config -> do
                                                                    drafts <-
                                                                        either
                                                                            (fail . show)
                                                                            pure
                                                                            ( planDraftsFromValidatedBuilder
                                                                                runRoot
                                                                                config
                                                                                (\_ _ -> Right stepPlan)
                                                                            )
                                                                    action <-
                                                                        either
                                                                            (fail . show)
                                                                            pure
                                                                            (withProjectPlan profile runRoot config drafts (\plan -> pure (use plan value)))
                                                                    action
                                                            either fail pure validated
                                                        )
                                                )
                                        either (fail . show) id opened
                                either (fail . show) id scoped
                        )
            ownershipResult <- either (fail . show) pure rooted
            case ownershipResult of
                Left reason -> fail reason
                Right (result, Nothing) -> pure result
                Right (_, Just failure) -> fail ("Harness fixture cleanup failed: " ++ show failure)

{- | Admit one real Production project plan whose validated configuration
retains the exact context selected from the fixture's canonical host context.

The selected context is returned beside the plan so a test can feed that exact
value to 'HostBootstrap.ProjectPlan.Frame.withCurrentFrame'.  Child-frame tests
select it with 'Context.deriveVMContext' and 'Context.deriveContainerContext';
the compatibility wrapper above selects the root context unchanged.
-}
withFixtureProjectPlanContext ::
    (BinaryContext -> BinaryContext) ->
    StepPlan ->
    ( forall projectId specDigest planId configId.
      ProjectPlan
        (V.Production projectId)
        specDigest
        planId
        configId
        ProjectConfig ->
      BinaryContext ->
      IO result
    ) ->
    IO result
withFixtureProjectPlanContext selectContext stepPlan use =
    withFixtureProjectPlanConfig
        (\value -> value{context = selectContext value.context})
        stepPlan
        (\plan value -> use plan value.context)

-- | Transform the real scoped configuration before canonical validation and admission.
withFixtureProjectPlanConfig ::
    (forall scope. ProjectConfig scope -> ProjectConfig scope) ->
    StepPlan ->
    ( forall projectId specDigest planId configId.
      ProjectPlan (V.Production projectId) specDigest planId configId ProjectConfig ->
      ProjectConfig (V.Production projectId) ->
      IO result
    ) ->
    IO result
withFixtureProjectPlanConfig transform stepPlan use =
    withSystemTempDirectory "hostbootstrap-fixture-project-plan" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
        withFixtureInstalledProject $ \project -> do
            rooted <-
                withCanonicalProjectRoot
                    (directory </> "fixture.dhall")
                    "."
                    ( \root ->
                        withProductionRoot store project Authority.ProjectUp $ \productionRoot -> do
                            opened <-
                                withProductionLifecycleProfile
                                    (Authority.rootScopeAuthority (productionRootAuthority productionRoot))
                                    (productionActiveMode (productionRootModeLease productionRoot))
                                    (productionRootUnboundLease productionRoot)
                                    ( \profile ->
                                        withProductionProjectCodec @ProjectConfig $ \codec -> do
                                            let rootValue =
                                                    defaultProjectConfig
                                                        (Authority.installedProjectName project)
                                                        (T.pack (canonicalProjectRootPath root))
                                                        Context.HostOrchestrator
                                                value = transform rootValue
                                            validated <-
                                                withValidatedConfig codec value $ \_wire config -> do
                                                    drafts <-
                                                        either
                                                            (fail . show)
                                                            pure
                                                            ( planDraftsFromValidatedBuilder
                                                                root
                                                                config
                                                                (\_ _ -> Right stepPlan)
                                                            )
                                                    action <-
                                                        either
                                                            (fail . show)
                                                            pure
                                                            ( withProjectPlan
                                                                profile
                                                                root
                                                                config
                                                                drafts
                                                                (\plan -> use plan value)
                                                            )
                                                    action
                                            either fail pure validated
                                    )
                            result <- either (fail . show) id opened
                            pure (Right result)
                    )
            modeResult <- either (fail . show) pure rooted
            either (fail . show) pure modeResult

{- | Admit a real Production plan while retaining the exact store, installed
project, and root that produced it. Recovery specs use this to exercise
protected snapshot-indexed folds without manufacturing any authority.
-}
withFixtureProjectPlanRoot ::
    StepPlan ->
    ( forall projectId brokerGeneration specDigest planId configId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      ProductionRoot projectId brokerGeneration VerbUp ->
      ProjectPlan (V.Production projectId) specDigest planId configId ProjectConfig ->
      IO result
    ) ->
    IO result
withFixtureProjectPlanRoot stepPlan use =
    withSystemTempDirectory "hostbootstrap-fixture-project-plan-root" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
        withFixtureInstalledProject $ \project -> do
            rooted <-
                withCanonicalProjectRoot (directory </> "fixture.dhall") "." $ \root ->
                    withProductionRoot store project Authority.ProjectUp $ \productionRoot -> do
                        opened <-
                            withProductionLifecycleProfile
                                (Authority.rootScopeAuthority (productionRootAuthority productionRoot))
                                (productionActiveMode (productionRootModeLease productionRoot))
                                (productionRootUnboundLease productionRoot)
                                ( \profile ->
                                    withProductionProjectCodec @ProjectConfig $ \codec -> do
                                        let value =
                                                defaultProjectConfig
                                                    (Authority.installedProjectName project)
                                                    (T.pack (canonicalProjectRootPath root))
                                                    Context.HostOrchestrator
                                        validated <-
                                            withValidatedConfig codec value $ \_wire config -> do
                                                drafts <-
                                                    either (fail . show) pure $
                                                        planDraftsFromValidatedBuilder root config (\_ _ -> Right stepPlan)
                                                action <-
                                                    either (fail . show) pure $
                                                        withProjectPlan profile root config drafts $
                                                            \plan -> use store project productionRoot plan
                                                action
                                        either fail pure validated
                                )
                        result <- either (fail . show) id opened
                        pure (Right result)
            modeResult <- either (fail . show) pure rooted
            either (fail . show) pure modeResult

data Resources = Resources
    { cpu :: Natural
    , memory :: Text
    , storage :: Text
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

newtype DeployConfig = DeployConfig
    { haReplicas :: Natural
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

newtype TestConfig = TestConfig
    { testResources :: Resources
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

instance TestCfg TestConfig where
    type TestVariant TestConfig = Text
    projectTestMatrix caseIds _ =
        mkTestMatrix
            caseIds
            [variantDraft defaultVariant "fixture-default", variantDraft alternateVariant "fixture-alternate"]
            [(cid, [defaultVariant, alternateVariant]) | cid <- caseIds]
      where
        defaultVariant = literalVariantId "default"
        alternateVariant = literalVariantId "alternate"

-- | Type-level identity for the core test fixture project.
data FixtureProject

-- | A second installed-project identity used by scope/secret API tests.
data SecretFixtureProject

data ProjectConfig scope = ProjectConfig
    { dockerfile :: Text
    , resources :: Resources
    , context :: BinaryContext
    , deploy :: DeployConfig
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

instance ProjectCfg ProjectConfig where
    withProductionProjectCodec =
        withProjectCodec "fixture/Production" projectConfigCodec
    withHarnessProjectCodec _ =
        withProjectCodec "fixture/Harness" projectConfigCodec
    cfgContext = context

instance BudgetCfg ProjectConfig where
    budgetResourceEnvelope value =
        let declared = value.resources
         in Context.ResourceEnvelope declared.cpu declared.memory declared.storage

{- | A secrets-strict project-owned config family. The secret field carries the
same scope index as the whole config and the type itself has no direct Dhall
decoder.
-}
data SecretProjectConfig scope = SecretProjectConfig
    { secretContext :: BinaryContext
    , secret :: V.SecretRef scope
    }
    deriving (Eq, Show)

data ProductionSecretProjectWire = ProductionSecretProjectWire
    { secretContext :: BinaryContext
    , secret :: V.ProductionSecretRefWire
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

data HarnessSecretProjectWire = HarnessSecretProjectWire
    { secretContext :: BinaryContext
    , secret :: V.HarnessSecretRefWire
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

productionSecretProjectWireCodec :: CodecWitness ProductionSecretProjectWire
productionSecretProjectWireCodec =
    requireCodecWitness "fixture ProductionSecretProjectWire" autoCodecWitness

harnessSecretProjectWireCodec :: CodecWitness HarnessSecretProjectWire
harnessSecretProjectWireCodec =
    requireCodecWitness "fixture HarnessSecretProjectWire" autoCodecWitness

instance ProjectCfg SecretProjectConfig where
    withProductionProjectCodec =
        withMappedProjectCodec
            "fixture secrets/Production"
            productionSecretProjectWireCodec
            ( \(SecretProjectConfig cfgContext' cfgSecret) ->
                ProductionSecretProjectWire
                    cfgContext'
                    (V.productionSecretRefWire cfgSecret)
            )
            ( \(ProductionSecretProjectWire cfgContext' cfgSecret) ->
                Right
                    ( SecretProjectConfig
                        cfgContext'
                        (V.productionSecretRef cfgSecret)
                    )
            )
    withHarnessProjectCodec authority =
        withMappedProjectCodec
            "fixture secrets/Harness"
            harnessSecretProjectWireCodec
            ( \(SecretProjectConfig cfgContext' cfgSecret) ->
                HarnessSecretProjectWire
                    cfgContext'
                    (V.harnessSecretRefWire cfgSecret)
            )
            ( \(HarnessSecretProjectWire cfgContext' cfgSecret) ->
                Right
                    ( SecretProjectConfig
                        cfgContext'
                        (V.harnessSecretRef authority cfgSecret)
                    )
            )
    cfgContext (SecretProjectConfig cfgContext' _) = cfgContext'

projectConfigCodec :: CodecWitness (ProjectConfig scope)
projectConfigCodec =
    requireCodecWitness "fixture ProjectConfig" autoCodecWitness

testConfigCodec :: CodecWitness TestConfig
testConfigCodec =
    requireCodecWitness "fixture TestConfig" (autoCodecWitness @TestConfig)

{- | An explicitly installed projector for tests whose subject never reaches
forward-child planning.  It preserves the production requirement that a
real ProjectSpec installs exactly one projector without inventing runtime
projection coverage in unrelated fixtures.
-}
refusingForwardChildPlan ::
    ProjectConfig scope ->
    Text ->
    Text ->
    LiftContext ->
    Either String (FilePath, ProjectConfig scope, StepPlan)
refusingForwardChildPlan _ _ _ _ =
    Left "the fixture does not exercise forward-child projection"

{- | A forward-child projector that really projects one VM descent.

The project-owned projector is the only function the immediate-target kernel
calls to obtain a child descriptor, configuration, and step plan, so a suite
whose every fixture refuses can never reach admitted recursive descent.  This
one derives the child configuration from the parent's own retained context
exactly as the kernel's expected-context derivation does, roots it at the
supplied canonical POSIX descriptor, and rebuilds the same declared chain so
the projected plan's frame labels, parent edges, and descent lifts are the
parent's own.
-}
projectingForwardChildPlan ::
    FilePath ->
    [Step] ->
    ProjectConfig scope ->
    Text ->
    Text ->
    LiftContext ->
    Either String (FilePath, ProjectConfig scope, StepPlan)
projectingForwardChildPlan descriptor steps parent _parentFrame _childFrame _route = do
    childConfig <-
        deriveProjectConfigForKind Context.VMOrchestrator parent (T.pack descriptor)
    childPlan <- either (Left . show) Right (mkStepPlan steps)
    Right (descriptor, childConfig, childPlan)

defaultResources :: Resources
defaultResources = Resources{cpu = 4, memory = "8GiB", storage = "20GiB"}

defaultDeployConfig :: DeployConfig
defaultDeployConfig = DeployConfig{haReplicas = 1}

defaultDockerfile :: Text
defaultDockerfile = "docker/Dockerfile"

projectConfigForRole ::
    Text ->
    Text ->
    Text ->
    Text ->
    Resources ->
    DeployConfig ->
    Context.ContextKind ->
    ProjectConfig scope
projectConfigForRole projectName binaryName root cfgDockerfile cfgResources cfgDeploy kind =
    ProjectConfig
        { dockerfile = cfgDockerfile
        , resources = cfgResources
        , context =
            Context.contextForKind
                projectName
                binaryName
                root
                kind
        , deploy = cfgDeploy
        }

projectConfigFromContext :: Text -> Resources -> DeployConfig -> Context.BinaryContext -> ProjectConfig scope
projectConfigFromContext cfgDockerfile cfgResources cfgDeploy cfgContext' =
    ProjectConfig
        { dockerfile = cfgDockerfile
        , resources = cfgResources
        , context = cfgContext'
        , deploy = cfgDeploy
        }

defaultProjectConfig :: Text -> Text -> Context.ContextKind -> ProjectConfig scope
defaultProjectConfig projectName root =
    projectConfigForRole projectName projectName root defaultDockerfile defaultResources defaultDeployConfig

defaultTestConfig :: Resources -> TestConfig
defaultTestConfig res = TestConfig{testResources = res}

literalVariantId :: Text -> VariantId
literalVariantId value =
    either (error . ("invalid fixture variant id: " ++) . show) id (mkVariantId value)

renderProjectConfig :: ProjectConfig scope -> Text
renderProjectConfig = renderHoistedValue projectConfigCodec Context.vocabUnions

decodeProjectConfigText :: Text -> IO (ProjectConfig scope)
decodeProjectConfigText = decodeText projectConfigCodec

decodeProjectConfigFile :: FilePath -> IO (ProjectConfig scope)
decodeProjectConfigFile = decodeFile projectConfigCodec

renderTestConfig :: TestConfig -> Text
renderTestConfig = renderValue testConfigCodec

decodeTestConfigText :: Text -> IO TestConfig
decodeTestConfigText = decodeText testConfigCodec

projectConfigSchemaText :: Text
projectConfigSchemaText = codecSchemaText projectConfigCodec

deriveProjectConfigForKind ::
    Context.ContextKind ->
    ProjectConfig scope ->
    Text ->
    Either String (ProjectConfig scope)
deriveProjectConfigForKind kind parent root
    | kind `notElem` Context.childContextKinds parentContext =
        Left $
            "project config: child context "
                <> show kind
                <> " is not allowed in "
                <> show (Context.contextKind parentContext)
    | otherwise =
        case kind of
            Context.HostOrchestrator ->
                Left "project config: host-orchestrator is not a child context"
            Context.VMOrchestrator ->
                projected (Context.deriveVMContext parentContext root)
            Context.VMProjectContainer ->
                projected (Context.deriveContainerContext parentContext root)
            Context.ImageBuildContainer ->
                Left "project config: image-build-container is not a child context"
            Context.ClusterService ->
                projected (Context.deriveServiceContext parentContext root)
            Context.Daemon ->
                projected (Context.deriveDaemonContext parentContext root)
            Context.OneShotJob ->
                projected (Context.deriveOneShotContext parentContext root)
            Context.TestHarness ->
                projected (Context.deriveTestHarnessContext parentContext root)
  where
    ProjectConfig
        { dockerfile = parentDockerfile
        , resources = parentResources
        , context = parentContext
        , deploy = parentDeploy
        } = parent
    projected = Right . projectConfigFromContext parentDockerfile parentResources parentDeploy

{- | The fixture's @init@ builder (mirrors the demo's @demoInit@), the only
default-bearing function: interpret the parsed flags into a 'ProjectConfig',
filling omitted knobs from the fixture defaults.
-}
projectInit :: Text -> InitArgs -> ProjectConfig scope
projectInit projectName args =
    let cfgResources =
            Resources
                { cpu = fromMaybe defaultResources.cpu args.mCpu
                , memory = fromMaybe defaultResources.memory args.memory
                , storage = fromMaybe defaultResources.storage args.storage
                }
        cfgDeploy = DeployConfig{haReplicas = fromMaybe defaultDeployConfig.haReplicas args.haReplicas}
        cfgDockerfile = fromMaybe defaultDockerfile args.dockerfile
        root = fromMaybe "." args.sourceRoot
        baseCfg =
            projectConfigForRole
                projectName
                projectName
                (T.pack root)
                cfgDockerfile
                cfgResources
                cfgDeploy
                args.role
     in case foldM (flip Context.addRole) baseCfg.context args.alsoRoles of
            Left err -> error (Context.contextErrorMessage err)
            Right ctx -> baseCfg{context = ctx}

-- | A defaultless 'InitArgs' for a chosen role (used by the spec builders).
initArgsFor :: Context.ContextKind -> InitArgs
initArgsFor kind =
    InitArgs
        { role = kind
        , alsoRoles = []
        , output = Nothing
        , sourceRoot = Just "/workspace/demo"
        , mCpu = Nothing
        , memory = Nothing
        , storage = Nothing
        , dockerfile = Nothing
        , haReplicas = Nothing
        , existingOutput = RefuseExistingOutput
        }

{- | Admit a throwaway 'CanonicalProjectRoot' for tests that need the root the
plan is built under (§ X). It goes through the production
'withCanonicalProjectRoot' bracket against a real directory rather than
fabricating the opaque value, which the type does not permit anyway.
-}
withFixtureProjectRoot ::
    (forall rootScope rootId. CanonicalProjectRoot rootScope rootId -> IO a) ->
    IO a
withFixtureProjectRoot action =
    withSystemTempDirectory "hostbootstrap-fixture-root" $ \dir -> do
        outcome <- withCanonicalProjectRoot (dir </> "fixture.dhall") "." action
        either (fail . show) pure outcome

-- ---------------------------------------------------------------------------
-- Spec-chosen stand-in executables launched by the command interpreter

{- | Write a stand-in executable whose output a spec chooses.

Production resolves it through @hcToolPaths@ and launches it through the normal
interpreter. A case using this helper proves the code's reaction to that raw
output and exit status; it establishes no real Docker or Incus behaviour.
The returned path is absolute. An empty report prints nothing.
-}
newFakeTool ::
    -- | the directory the tool is written into
    FilePath ->
    -- | its base name, without a host-specific extension
    String ->
    -- | exactly what it writes to standard output, one line, or nothing
    String ->
    IO FilePath
newFakeTool directory name reported = do
    let path = directory </> fakeToolFileName name
    writeFile path (fakeToolProgram reported)
    makeFakeToolExecutable path
    pure path

fakeToolFileName :: String -> String
fakeToolProgram :: String -> String
makeFakeToolExecutable :: FilePath -> IO ()
#if defined(mingw32_HOST_OS)
fakeToolFileName name = name <> ".bat"
fakeToolProgram "" = "@echo off\n"
fakeToolProgram reported = unlines ("@echo off" : map (("echo(" <>) . escapeCmdEcho) (lines reported))
makeFakeToolExecutable _ = pure ()
#else
fakeToolFileName = id
fakeToolProgram "" = "#!/bin/sh\nexit 0\n"
fakeToolProgram reported = "#!/bin/sh\nprintf '%s\\n' " <> quotePosix reported <> "\n"
makeFakeToolExecutable path =
    getPermissions path >>= setPermissions path . setOwnerExecutable True
#endif

{- | Write a spec-chosen stand-in that answers once and then exits non-zero.

Its temporary calls marker controls only the scripted raw process response.
Production still resolves the tool through @hcToolPaths@. These observations
test the code's reaction to the supplied status and streams, not real provider
readiness or availability.
-}
newExhaustingFakeTool ::
    -- | the directory the tool is written into
    FilePath ->
    -- | its base name, without a host-specific extension
    String ->
    -- | exactly what its one successful call writes to standard output
    String ->
    -- | the diagnostic every later call writes to standard error
    String ->
    IO FilePath
newExhaustingFakeTool directory name reported diagnostic = do
    let path = directory </> fakeToolFileName name
    writeFile path (exhaustingToolProgram reported diagnostic)
    makeFakeToolExecutable path
    pure path

exhaustingToolProgram :: String -> String -> String
#if defined(mingw32_HOST_OS)
exhaustingToolProgram reported diagnostic =
    unlines
        ( [ "@echo off"
          , "if exist \"%~f0.calls\" goto exhausted"
          , "type nul > \"%~f0.calls\""
          ]
            <> map (("echo(" <>) . escapeCmdEcho) (lines reported)
            <> ["exit /b 0", ":exhausted"]
            <> map (("1>&2 echo(" <>) . escapeCmdEcho) (lines diagnostic)
            <> ["exit /b 1"]
        )
#else
exhaustingToolProgram reported diagnostic =
    unlines
        [ "#!/bin/sh"
        , "calls=\"$0.calls\""
        , "if [ -f \"$calls\" ]; then"
        , "  printf '%s\\n' " <> quotePosix diagnostic <> " >&2"
        , "  exit 1"
        , "fi"
        , ": > \"$calls\""
        , "printf '%s\\n' " <> quotePosix reported
        ]
#endif

{- | Write a spec-chosen stand-in that records its invocation and answers.

The temporary invocation file lets a case inspect process order. Production
resolves this tool through @hcToolPaths@; the selected status and streams establish
the code's reaction to those inputs and no real Docker or Incus behaviour.
-}
newRecordingFakeTool ::
    -- | the directory the tool is written into
    FilePath ->
    -- | its base name, without a host-specific extension
    String ->
    -- | exactly what it writes to standard output, one line, or nothing
    String ->
    -- | the status it exits with
    Int ->
    -- | the log it appends its own name to
    FilePath ->
    IO FilePath
newRecordingFakeTool directory name reported status logPath = do
    let path = directory </> fakeToolFileName name
    writeFile path (recordingToolProgram name reported status logPath)
    makeFakeToolExecutable path
    pure path

recordingToolProgram :: String -> String -> Int -> FilePath -> String
#if defined(mingw32_HOST_OS)
recordingToolProgram name reported status logPath =
    unlines
        ( [ "@echo off"
          , "echo " <> name <> ">>\"" <> logPath <> "\""
          ]
            <> map ("echo(" <>) (map escapeCmdEcho (lines reported))
            <> ["exit /b " <> show status]
        )
#else
recordingToolProgram name reported status logPath =
    unlines
        ( [ "#!/bin/sh"
          , "printf '%s\\n' " <> quotePosix name <> " >> " <> quotePosix logPath
          ]
            <> ["printf '%s\\n' " <> quotePosix reported | not (null reported)]
            <> ["exit " <> show status]
        )
#endif

#if defined(mingw32_HOST_OS)
escapeCmdEcho :: String -> String
escapeCmdEcho = concatMap escape
  where
    escape '^' = "^^"
    escape '%' = "%%"
    escape '&' = "^&"
    escape '|' = "^|"
    escape '<' = "^<"
    escape '>' = "^>"
    escape '"' = "^\""
    escape '(' = "^("
    escape ')' = "^)"
    escape character = [character]
#else
quotePosix :: String -> String
quotePosix value = "'" <> concatMap quote value <> "'"
  where
    quote '\'' = "'\\''"
    quote character = [character]
#endif
