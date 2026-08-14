{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

{- | The core @optparse-applicative@ command tree.

'coreCommands' is the list of fixed core subcommand entries every derived
binary exposes. 'allReconcilers' is the concrete reconciler library projects
compose into @ensure-*@ chain steps.

The command tree is **generic over a project's scope-indexed config family**
('ProjectCfg'): it never names a concrete config record. It decodes/encodes the
sibling config through a scope-correct 'ProjectCodec', reaches the embedded
context through 'cfgContext', and obtains project config solely from the
project-owned restricted assembler threaded in from the spec — the **only**
place project-config defaults live.
-}
module HostBootstrap.Command (
    coreCommands,
    coreCommandNames,
    allReconcilers,
    LifecycleEntry,
    lifecycleEntryFrameName,
    lifecycleEntryVerbName,
)
where

import Control.Exception (SomeException, displayException, mask, throwIO)
import Control.Exception.Safe (finally, try)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Control.Monad (unless, when)
import Data.List (find, intercalate, isInfixOf, stripPrefix)
import qualified Data.Text as T
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Chain (
    nextFrameAfter,
    renderChain,
 )
import HostBootstrap.Command.LifecycleEntry
    ( LifecycleEntry
    , lifecycleEntryFrameName
    , lifecycleEntryVerbName
    , runRootProjectUpLifecycleEntry
    , withRootProjectUpLifecycleEntry
    )
import HostBootstrap.Cluster.Lifecycle (
    ClusterPlan,
    ClusterProfile (Production),
    clusterDelete,
    clusterDown,
    resolvePlan,
 )
import HostBootstrap.Config.Class (
    AssemblyRequest (..),
    ConfigAssembly,
    ConfigInput,
    InitArgs (..),
    ProjectCfg (..),
    ProjectCodec,
    TestCfg (..),
    decodeProjectCodecFile,
    projectCodecSchemaText,
    projectCodecSpecDigest,
 )
import HostBootstrap.Config.Fields (inspectLocalContext)
import HostBootstrap.Config.Schema (
    ValidatedConfig,
    configRoleNames,
    parseConfigRole,
    projectConfigFileName,
    renderScopedProjectConfigBytes,
    siblingProjectConfigPath,
    validatedConfigValue,
    verifiedConfigDigest,
    withAssembledHarnessConfig,
    withSiblingProjectConfigContext,
    withSiblingValidatedProjectConfigContext,
    withSiblingValidatedProjectConfigRoot,
    TestConfigReplacement (RefuseExistingTestConfig, ReplaceExistingTestConfig),
    TestConfigWriteOutcome (TestConfigExists, TestConfigReplaced, TestConfigWritten),
    installTestConfig,
    siblingTestConfigPath,
    testConfigWriteFor,
    writeScopedProjectConfigFile,
 )
import qualified HostBootstrap.Config.Vocab as V
import qualified HostBootstrap.Context as Context
import qualified HostBootstrap.Lifecycle.Context as LifecycleContext
import HostBootstrap.Dhall.Gen (
    CodecWitness,
    ConfigArtifact,
    artifactName,
    coreArtifacts,
    decodeFile,
    renderText,
    schemaUnion,
 )
import HostBootstrap.Ensure (Reconciler)
import qualified HostBootstrap.Ensure.AppleMetal as AppleMetal
import qualified HostBootstrap.Ensure.Cuda as Cuda
import qualified HostBootstrap.Ensure.CudaWin as CudaWin
import qualified HostBootstrap.Ensure.Docker as Docker
import qualified HostBootstrap.Ensure.Ghc as Ghc
import qualified HostBootstrap.Ensure.Homebrew as Homebrew
import qualified HostBootstrap.Ensure.Incus as Incus
import qualified HostBootstrap.Ensure.Lima as Lima
import qualified HostBootstrap.Ensure.Wsl2 as Wsl2
import HostBootstrap.Harness (
    ConfigVariant (..),
    LifecycleFailure (..),
    SafetyRefusal (..),
    TestMatrixError (..),
    TestSuite,
    allCasesSelector,
    allPassed,
    caseIdText,
    parseCaseSelector,
    reportCard,
    refusedObservationMarker,
    runSuiteSelection,
    safetyRefusalMarker,
    selectTestMatrix,
    selectedVariantCaseIds,
    selectedVariantDraft,
    testDataRoot,
    testMatrixCaseIds,
    testSuiteCaseIds,
    variantDraftId,
    variantIdText,
 )
import HostBootstrap.Harness.Ownership (
    acquireOwnedRunConfig,
    ownedHarnessConfigPath,
    protectedProjectRunOwnership,
    releaseOwnedRunConfig,
    withOwnedHarnessRoot,
 )
import HostBootstrap.Harness.Lifecycle.Internal (harnessLifecycle)
import HostBootstrap.Harness.Ownership.Internal (
    armOwnedHarnessBoundClose,
    beginOwnedHarnessBinding,
    markOwnedHarnessClosePending,
    settleOwnedHarnessClose,
 )
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.Lifecycle.Mode (
    BoundRunLease,
    ModeError (..),
    ProductionMode,
    ProductionRoot,
    ProjectModeLease,
    VerifiedPlanSnapshot,
    authorizeHarnessClose,
    currentHarnessCloseRoot,
    destroySettledClosure,
    harnessActiveMode,
    harnessRootAuthority,
    harnessRootHarnessAuthority,
    harnessRootModeLease,
    harnessRootRunId,
    harnessRootUnboundLease,
    modeErrorMessage,
    planSnapshotSpecDigest,
    productionActiveMode,
    productionRootAuthority,
    productionRootModeLease,
    productionRootUnboundLease,
    verifyBoundRunHasNoProjectResourcesAcquired,
    withHarnessLifecycleProfile,
    withProductionLifecycleProfile,
    withProductionRoot,
    withRecoveredProductionLifecycleProfile,
 )
import HostBootstrap.Lift (
    SelfRef,
    currentSelfRef,
    liftStdin,
    liftSubcommandWithStdin,
 )
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import HostBootstrap.ProjectPlan.Construct
    ( FinalizedProjectSpec
    , finalizedProjectCodec
    , projectPlanDrafts
    , withFinalizedProjectSpecParts
    , withHarnessFinalizedProjectSpec
    , withProjectPlan
    , withRecoveredProductionProjectPlan
    , withRecoveredProductionProjectPlanInputs
    )
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    forward,
    plannedStepFrameId,
    plannedStepIdentity,
    renderSnapshot,
    stablePlanSnapshotDigest,
    topology,
 )
import HostBootstrap.ProjectPlan.Frame (
    CurrentFrame,
    ProjectFrame,
    ValidatedContext,
    currentFrameId,
    validatedContextValue,
    withCurrentFrame,
 )
import HostBootstrap.ProjectPlan.Snapshot (
    BoundPlanSnapshot,
    PlanDigestBinding,
    SnapshotError (..),
    withBoundPlanSnapshot,
    withPersistedPlanSnapshot,
 )
import HostBootstrap.Protected (
    ProtectedStore,
    openProtectedStore,
    protectedErrorMessage,
    withProtectedEntry,
 )
import HostBootstrap.Lifecycle.Session (sessionErrorMessage, verifyAllSessionsClosed)
import HostBootstrap.RoleLifecycle (RoleEffect, roleEffectName)
import HostBootstrap.Service (
    FinalizedServiceRegistry,
    finalizedServiceVariantNames,
    serviceIdText,
    serviceRoleSchemaFamilies,
    withSelectedServiceRequest,
 )
import HostBootstrap.Step (
    CoreStepId (DeployKindId),
    StepIdentity (CoreStepIdentity),
 )
import qualified HostBootstrap.Step as Step
import HostBootstrap.Substrate (detect)
import qualified HostBootstrap.Teardown as Teardown
import Numeric.Natural (Natural)
import Options.Applicative
import System.Directory (doesFileExist, getCurrentDirectory, withCurrentDirectory)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitSuccess), die)
import System.FilePath (takeDirectory, (</>))

{- | The context-free @ensure@ reconciler library — the host-configuration
primitives, including the cross-substrate host-provider @incus@ reconciler.
Project/config/plan-dependent provider adapters such as the prepared Colima
wall cannot appear in this list.
-}
allReconcilers :: [Reconciler]
allReconcilers =
    [ Docker.reconciler
    , AppleMetal.reconciler
    , Cuda.reconciler
    , CudaWin.reconciler
    , Homebrew.reconciler
    , Ghc.reconciler
    , Lima.reconciler
    , Incus.reconciler
    , Wsl2.reconciler
    ]

{- | The top-level core command names. The surface is fixed and closed; projects
extend behavior through the 'ProjectSpec' streams, not new verbs.
-}
coreCommandNames :: [String]
coreCommandNames = ["context", "project", "test", "service", "check-code"]

{- | The core subcommands every @hostbootstrap@-derived binary exposes. The
project's 'TestSuite' is threaded into the inherited @test@ verb so a project's
cases run under @test@ (not a per-noun subcommand). The project's config seams
are threaded in too: @project init@ uses the Production request of the single
restricted assembler, @test init@ writes via 'psTestInit', and @test run@
generates each exact-run-scoped config through the Harness request.
-}
coreCommands ::
    forall projectId cfg tcfg specDigest.
    (ProjectCfg cfg, TestCfg tcfg) =>
    Authority.InstalledProjectIdentity projectId ->
    FinalizedProjectSpec (V.Production projectId) specDigest cfg ->
    CodecWitness tcfg ->
    String ->
    [ConfigArtifact] ->
    TestSuite ->
    IO () ->
    [ConfigInput] ->
    ( forall scope.
      AssemblyRequest projectId tcfg (TestVariant tcfg) scope ->
      ConfigAssembly scope (cfg scope)
    ) ->
    (InitArgs -> IO (cfg (V.Production projectId))) ->
    (InitArgs -> tcfg) ->
    [Mod CommandFields (IO ())]
coreCommands project finalizedSpec testCodec progName projectArtifacts suite checkCode assemblyInputs assemble initBuilder testInit =
    withFinalizedProjectSpecParts finalizedSpec $ \cfgCodec services _scopePlanBuilder ->
        [ contextCommand @cfg @(V.Production projectId) cfgCodec progName projectArtifacts initBuilder
        , projectCommandGroup project finalizedSpec progName initBuilder
        , testCommand @projectId @cfg @tcfg project finalizedSpec testCodec progName suite assemblyInputs assemble testInit
        , serviceCommandGroup cfgCodec progName services initBuilder
        , checkCodeCommand @cfg @(V.Production projectId) cfgCodec progName checkCode
        ]

gate ::
    forall cfg configScope specDigest.
    (ProjectCfg cfg) =>
    ProjectCodec configScope specDigest cfg ->
    String ->
    Context.CommandClass ->
    [Context.Capability] ->
    IO () ->
    IO ()
gate codec progName commandClass caps body =
    withSiblingProjectConfigContext codec (T.pack progName) commandClass caps (\(_ :: cfg configScope) _ -> body)

{- | The @test@ verb: a two-subcommand surface (@init@ and @run@). @test run@
selects over the project's case matrix and prints the report card — @test run
all@ runs the whole matrix; @test run \<case\>@ runs the single case with that id
(an unknown id fails fast, listing the valid ids). The bare binary reaches this
through the explicit bare entrypoint; a project supplies its non-empty matrix and
seams as the 'TestSuite' threaded through 'HostBootstrap.CLI.runHostBootstrapCLI'.

@test init@ writes the project's test config via 'psTestInit' (it needs **no**
pre-existing project config — a bootstrap entrypoint). @test run@ reads that test
config, builds each run's project config through the Harness request of the
restricted assembler and its matching codec, writes it as the sibling
@<project>.dhall@, drives the suite against the live stack, then deletes the
**generated** config (keeping the test config).
-}
testCommand ::
    forall projectId cfg tcfg specDigest.
    (ProjectCfg cfg, TestCfg tcfg) =>
    Authority.InstalledProjectIdentity projectId ->
    FinalizedProjectSpec (V.Production projectId) specDigest cfg ->
    CodecWitness tcfg ->
    String ->
    TestSuite ->
    [ConfigInput] ->
    ( forall scope.
      AssemblyRequest projectId tcfg (TestVariant tcfg) scope ->
      ConfigAssembly scope (cfg scope)
    ) ->
    (InitArgs -> tcfg) ->
    Mod CommandFields (IO ())
testCommand project productionSpec testCodec progName suite assemblyInputs assemble testInit =
    command
        "test"
        ( info
            (hsubparser (testInitCmd <> testRunCmd))
            (progDesc "Test surface: `init` writes <project>.test.dhall; `run` runs compiled cases against the live stack (root-only)")
        )
  where
    testInitCmd =
        command
            "init"
            ( info
                (runTestInit <$> replaceFlag)
                (progDesc "Write <project>.test.dhall next to the project config (needs no pre-existing project config)")
            )
    {- The policy is a flag rather than a default, because both defaults are
    wrong: overwriting silently loses an edited matrix, and skipping silently
    runs yesterday's. -}
    replaceFlag =
        flag
            RefuseExistingTestConfig
            ReplaceExistingTestConfig
            ( long "replace"
                <> help "replace an existing <project>.test.dhall instead of refusing"
            )
    testRunCmd =
        command
            "run"
            ( info
                (runTestRun <$> caseArg)
                (progDesc ("Run one compiled test case, or `" ++ allCasesSelector ++ "` for the whole matrix (needs <project>.test.dhall)"))
            )
    {- The selector's vocabulary is the compiled case registry, so the surface
    text names a case. It said @SUITE@, which described a grouping the typed
    vocabulary does not have: what a project contributes is a non-empty set of
    'Case's with validated 'CaseId's, and the only other selector is
    'allCasesSelector'. An operator reading @SUITE@ has no way to discover what
    to type, because nothing anywhere is named a suite. -}
    caseArg =
        argument
            (eitherReader (either (Left . show) Right . parseCaseSelector . T.pack))
            ( metavar "CASE-ID"
                <> help ("test case to run, or `" ++ allCasesSelector ++ "` for every compiled case")
            )
    -- @test init@ writes the project's test config from defaults (no flags, no
    -- pre-existing project config required): the project's 'psTestInit'
    -- interprets the same defaultless 'InitArgs' the harness uses.
    {- The writer takes an opaque request, not a path and not bytes: the
    request's producer resolves the sibling destination itself from the
    project's own name, and what a caller supplies is the project's typed
    test-config value. So @test init@ cannot be asked to write arbitrary bytes,
    or to write them anywhere but the file @test run@ reads. -}
    runTestInit replacement = do
        request <- testConfigWriteFor (T.pack progName) testCodec (testInit defaultInitArgs)
        outcome <- installTestConfig replacement request
        case outcome of
            TestConfigWritten path -> putStrLn ("test init: wrote " ++ path)
            TestConfigReplaced path -> putStrLn ("test init: replaced " ++ path)
            TestConfigExists path ->
                die
                    ( "test init: "
                        ++ path
                        ++ " already exists; pass --replace to overwrite it"
                    )
    -- @test run@ is not context-gated: it does NOT load a sibling project config
    -- (the harness generates it); its guards are the test config's existence
    -- precondition plus the suite's own safety preconditions.
    runTestRun selector = do
        tpath <- siblingTestConfigPath (T.pack progName)
        exists <- doesFileExist tpath
        unless exists (die ("test run: missing " ++ tpath ++ "; run `" ++ progName ++ " test init` first"))
        tc <- decodeFile testCodec tpath
        cfgPath <- siblingProjectConfigPath (T.pack progName)
        -- There is deliberately no `doesFileExist cfgPath` refusal here. That
        -- check used to fire *before* `withHarnessRoot` reached
        -- `recoverAbandonedHarnessRuns`, so after the common failure mode — an
        -- interrupted run leaving its own generated config behind — the sweep
        -- that would resolve it never ran, and both the config and the bound
        -- lease had to be cleared by hand. The authoritative refusal is
        -- `harnessPreconditions`, which derives its subject from installed
        -- project identity and runs inside the protected transaction, after the
        -- sweep (the test-harness-and-run-ownership phase).
        matrix <-
            either
                (die . ("test run: invalid test matrix: " ++) . show)
                pure
                (projectTestMatrix (testSuiteCaseIds suite) tc)
        when (testMatrixCaseIds matrix /= testSuiteCaseIds suite) $
            die "test run: project test-matrix projection did not preserve the executable Haskell case registry"
        selected <-
            either
                (die . selectionError matrix)
                pure
                (selectTestMatrix selector matrix)
        -- Exclusive run ownership is taken by the protected-store bracket, not
        -- by a bare lock directory: an interrupted run leaves a classifiable
        -- lease the next run's sweep resolves or names for recovery.
        siblingDirectory <- takeDirectory <$> siblingProjectConfigPath (T.pack progName)
        stateRoot <- getCurrentDirectory
        resolved <-
            withCanonicalProjectRoot cfgPath stateRoot $ \ownershipRoot -> do
                let variantFor selectedVariant =
                        ConfigVariant
                            { variantId = variantDraftId draft
                            , variantCaseIds = selectedVariantCaseIds selectedVariant
                            , variantWithLifecycle = \ownedRoot useLifecycle ->
                                withOwnedHarnessRoot ownedRoot $ \store ownedProject root closeControl -> do
                                    let authority = harnessRootHarnessAuthority root
                                        runName = V.harnessRunName authority
                                        rootAuthority = harnessRootAuthority root
                                        unbound = harnessRootUnboundLease root
                                    mask $ \restore -> do
                                        withHarnessFinalizedProjectSpec
                                            (V.harnessConfigAuthority authority)
                                            productionSpec
                                            ( \harnessSpec -> do
                                                let harnessCodec = finalizedProjectCodec harnessSpec
                                                assembled <-
                                                    restore
                                                        ( withAssembledHarnessConfig
                                                            assemblyInputs
                                                            authority
                                                            harnessCodec
                                                            (assemble (HarnessAssembly authority tc draft))
                                                            ( \_wire validated -> do
                                                                scoped <-
                                                                    withCanonicalProjectRoot cfgPath stateRoot $ \runRoot -> do
                                                                        opened <-
                                                                            withHarnessLifecycleProfile
                                                                                ( Authority.rootScopeAuthority
                                                                                    rootAuthority
                                                                                )
                                                                                authority
                                                                                (harnessRootRunId root)
                                                                                (harnessActiveMode (harnessRootModeLease root))
                                                                                unbound
                                                                                ( \profile -> do
                                                                                    drafts <-
                                                                                        either
                                                                                            (die . ("project plan: " ++) . show)
                                                                                            pure
                                                                                            (projectPlanDrafts harnessSpec runRoot validated)
                                                                                    planAction <-
                                                                                        either
                                                                                            (die . ("project plan: " ++) . show)
                                                                                            pure
                                                                                            ( withProjectPlan profile runRoot validated drafts $ \plan ->
                                                                                                case
                                                                                                    withCurrentFrame
                                                                                                        plan
                                                                                                        (cfgContext (validatedConfigValue validated))
                                                                                                        ( \current _frame admittedContext -> do
                                                                                                            lifecycleAdmitted <-
                                                                                                                LifecycleContext.withValidatedLifecycleContext
                                                                                                                    runRoot
                                                                                                                    store
                                                                                                                    plan
                                                                                                                    (validatedContextValue admittedContext)
                                                                                                                    ( \lifecycleContext ->
                                                                                                                        mask $ \restoreBound -> do
                                                                                                                bindingStarted <- beginOwnedHarnessBinding closeControl
                                                                                                                either (throwIO . LifecycleFailure) pure bindingStarted
                                                                                                                persisted <-
                                                                                                                    withPersistedPlanSnapshot
                                                                                                                        rootAuthority
                                                                                                                        unbound
                                                                                                                        plan
                                                                                                                        ( \verified bound binding lease _normalRecovery -> do
                                                                                                                            armed <- armOwnedHarnessBoundClose closeControl lease
                                                                                                                            either (throwIO . LifecycleFailure) pure armed
                                                                                                                            restoreBound $ do
                                                                                                                                ownedPayload <-
                                                                                                                                    either die pure
                                                                                                                                        =<< acquireOwnedRunConfig
                                                                                                                                            ownedRoot
                                                                                                                                            ( renderScopedProjectConfigBytes
                                                                                                                                                harnessCodec
                                                                                                                                                (validatedConfigValue validated)
                                                                                                                                            )
                                                                                                                                cfg <- hostConfig
                                                                                                                                self <- currentSelfRef ("/usr/local/bin/" ++ progName)
                                                                                                                                let forwardAction = do
                                                                                                                                        ran <-
                                                                                                                                            runExactProjectUp
                                                                                                                                                cfg
                                                                                                                                                self
                                                                                                                                                harnessSpec
                                                                                                                                                rootAuthority
                                                                                                                                                lease
                                                                                                                                                verified
                                                                                                                                                bound
                                                                                                                                                binding
                                                                                                                                                plan
                                                                                                                                                lifecycleContext
                                                                                                                                        either raiseForwardFailure pure ran
                                                                                                                                    reverseAction =
                                                                                                                                        mask $ \restoreReverse -> do
                                                                                                                                            settled <-
                                                                                                                                                restoreReverse
                                                                                                                                                    ( runExactDestroyProjection
                                                                                                                                                        progName
                                                                                                                                                        plan
                                                                                                                                                        current
                                                                                                                                                        runRoot
                                                                                                                                                        (cfgContext (validatedConfigValue validated))
                                                                                                                                                        cfg
                                                                                                                                                    )
                                                                                                                                            closing <- authorizeAndMarkClose settled
                                                                                                                                            case closing of
                                                                                                                                                Left failure -> throwIO (LifecycleFailure failure)
                                                                                                                                                Right closure -> do
                                                                                                                                                    closeSettled <- settleOwnedHarnessClose closeControl closure
                                                                                                                                                    either (throwIO . LifecycleFailure) pure closeSettled
                                                                                                                                    authorizeAndMarkClose settled = do
                                                                                                                                        entered <-
                                                                                                                                            withProtectedEntry store $ \protected -> do
                                                                                                                                                sessions <-
                                                                                                                                                    verifyAllSessionsClosed
                                                                                                                                                        protected
                                                                                                                                                        (stablePlanSnapshotDigest (renderSnapshot plan))
                                                                                                                                                case sessions of
                                                                                                                                                    Left failure ->
                                                                                                                                                        pure (Right (Left (sessionErrorMessage failure)))
                                                                                                                                                    Right closed ->
                                                                                                                                                        case destroySettledClosure lease closed settled of
                                                                                                                                                            Left failure ->
                                                                                                                                                                pure (Right (Left (T.unpack (modeErrorMessage failure))))
                                                                                                                                                            Right closure -> do
                                                                                                                                                                authorized <-
                                                                                                                                                                    authorizeHarnessClose
                                                                                                                                                                        protected
                                                                                                                                                                        ownedProject
                                                                                                                                                                        (currentHarnessCloseRoot root)
                                                                                                                                                                        (harnessRootModeLease root)
                                                                                                                                                                        lease
                                                                                                                                                                        closed
                                                                                                                                                                        closure
                                                                                                                                                                        1
                                                                                                                                                                pure . Right $ case authorized of
                                                                                                                                                                    Left failure -> Left (T.unpack (modeErrorMessage failure))
                                                                                                                                                                    Right authorization -> Right (closure, authorization)
                                                                                                                                        case entered of
                                                                                                                                            Left failure -> pure (Left (T.unpack (protectedErrorMessage failure)))
                                                                                                                                            Right (Left failure) -> pure (Left failure)
                                                                                                                                            Right (Right (closure, authorization)) -> do
                                                                                                                                                pending <- markOwnedHarnessClosePending closeControl authorization
                                                                                                                                                pure (closure <$ pending)
                                                                                                                                    raiseForwardFailure failure
                                                                                                                                        | not (isRefusal failure) =
                                                                                                                                            throwIO (LifecycleFailure failure)
                                                                                                                                        | otherwise = do
                                                                                                                                            noEffects <- verifyBoundRunHasNoProjectResourcesAcquired lease
                                                                                                                                            case noEffects of
                                                                                                                                                Right _ ->
                                                                                                                                                    throwIO (SafetyRefusal (refusalDetail failure))
                                                                                                                                                Left _ ->
                                                                                                                                                    throwIO (LifecycleFailure (lateRefusal failure))
                                                                                                                                    isRefusal failure =
                                                                                                                                        safetyRefusalMarker `isInfixOf` failure
                                                                                                                                            || refusedObservationMarker `isInfixOf` failure
                                                                                                                                    refusalDetail failure =
                                                                                                                                        case stripPrefix (safetyRefusalMarker ++ " ") failure of
                                                                                                                                            Just detail -> detail
                                                                                                                                            Nothing -> case stripPrefix (refusedObservationMarker ++ " ") failure of
                                                                                                                                                Just detail -> detail
                                                                                                                                                Nothing -> failure
                                                                                                                                    lateRefusal failure
                                                                                                                                        | refusedObservationMarker `isInfixOf` failure = failure
                                                                                                                                        | otherwise = refusedObservationMarker ++ " " ++ refusalDetail failure
                                                                                                                                    lifecycleBody =
                                                                                                                                        putStrLn
                                                                                                                                            ( "test run: generated the run config at "
                                                                                                                                                ++ ownedHarnessConfigPath ownedRoot
                                                                                                                                                ++ " (variant "
                                                                                                                                                ++ T.unpack (variantIdText (variantDraftId draft))
                                                                                                                                                ++ ", run "
                                                                                                                                                ++ T.unpack runName
                                                                                                                                                ++ ")"
                                                                                                                                            )
                                                                                                                                            >> useLifecycle
                                                                                                                                                (harnessLifecycle forwardAction reverseAction)
                                                                                                                                lifecycleBody
                                                                                                                                    `finally` removeGeneratedConfig ownedRoot ownedPayload
                                                                                                                        )
                                                                                                                either
                                                                                                                    (die . ("project snapshot: " ++) . show)
                                                                                                                    pure
                                                                                                                    persisted
                                                                                                                    )
                                                                                                            either
                                                                                                                (throwIO . LifecycleFailure . LifecycleContext.lifecycleContextErrorMessage)
                                                                                                                pure
                                                                                                                lifecycleAdmitted
                                                                                                        )
                                                                                                of
                                                                                                Left failure -> die ("project frame: " ++ show failure)
                                                                                                Right admittedAction -> admittedAction
                                                                                            )
                                                                                    planAction
                                                                                )
                                                                        either
                                                                            (die . T.unpack . Authority.authorityErrorMessage)
                                                                            id
                                                                            opened
                                                                either
                                                                    (die . ("test run: invalid project root: " ++) . show)
                                                                    pure
                                                                    scoped
                                                            )
                                                        )
                                                either die pure assembled
                                            )
                            }
                      where
                        draft = selectedVariantDraft selectedVariant
                    ownership =
                        protectedProjectRunOwnership
                            project
                            ownershipRoot
                            siblingDirectory
                            (canonicalProjectRootPath ownershipRoot </> testDataRoot)
                runSuiteSelection ownership suite (map variantFor selected)
        outcome <-
            either
                (die . ("test run: invalid project root: " ++) . show)
                pure
                resolved
        case outcome of
            Left err -> die err
            Right report -> do
                putStr (reportCard report)
                unless (allPassed report) (die "test: one or more cases failed")
    removeGeneratedConfig ownedRoot ownedPayload = do
        removed <- releaseOwnedRunConfig ownedRoot ownedPayload
        either die pure removed
    selectionError matrix err =
        case err of
            UnknownSelectedCase cid ->
                "unknown test case "
                    ++ show (T.unpack (caseIdText cid))
                    ++ "; available: "
                    ++ intercalate ", " (map (T.unpack . caseIdText) (testMatrixCaseIds matrix) ++ [allCasesSelector])
            _ -> "test run: invalid test-matrix selection: " ++ show err

{- | The defaultless @init@ flag bundle the @test init@ / harness path uses: no
output/source-root/role overrides, so the project's builder supplies all
defaults.
-}
defaultInitArgs :: InitArgs
defaultInitArgs =
    InitArgs
        { role = Context.HostOrchestrator
        , alsoRoles = []
        , output = Nothing
        , sourceRoot = Nothing
        , mCpu = Nothing
        , memory = Nothing
        , storage = Nothing
        , dockerfile = Nothing
        , haReplicas = Nothing
        , force = False
        , ifMissing = False
        }

{- | The @check-code@ verb: the fail-fast image-build quality gate. Its body is
supplied by the project spec (or by the explicit bare-core entrypoint).
-}
checkCodeCommand ::
    forall cfg configScope specDigest.
    (ProjectCfg cfg) =>
    ProjectCodec configScope specDigest cfg ->
    String ->
    IO () ->
    Mod CommandFields (IO ())
checkCodeCommand codec progName checkCode =
    command
        "check-code"
        ( info
            (pure (gate @cfg @configScope codec progName Context.CheckCodeCommand [] checkCode))
            (progDesc "Run the project's fail-fast code-check gate (project-defined body)")
        )

{- | The @context@ command group (§ Z): read-only composition introspection plus
the absorbed read-only config-inspection surfaces (@show@ / @schema@ / @render@ /
@path@). Child-config creation is the @context-init@ chain step inside @project
up@, not a @context@ subcommand; config generation is @project init@.
-}
contextCommand ::
    forall cfg configScope specDigest.
    (ProjectCfg cfg) =>
    ProjectCodec configScope specDigest cfg ->
    String ->
    [ConfigArtifact] ->
    (InitArgs -> IO (cfg configScope)) ->
    Mod CommandFields (IO ())
contextCommand codec progName projectArtifacts _initBuilder =
    command
        "context"
        ( info
            (hsubparser (inspectCmd <> showCmd <> schemaCmd <> renderCmd <> showPathCmd))
            (progDesc "Read-only: render the lift composition and inspect/describe the project-local config")
        )
  where
    artifacts = coreArtifacts ++ projectArtifacts

    showPathCmd =
        command
            "path"
            ( info
                (pure (putStrLn (projectConfigFileName (T.pack progName))))
                (progDesc "Print the canonical project-local config filename")
            )

    showCmd =
        command
            "show"
            ( info
                (showAction <$> fileArg progName)
                (progDesc "Decode a <project>.dhall and print its composition")
            )
    showAction path = do
        cfg <- readContextConfig path
        putStr (Context.renderComposition (cfgContext cfg))

    schemaCmd =
        command
            "schema"
            ( info
                (pure schemaAction)
                (progDesc "Print the Dhall schema the binary's decoders accept (the in-scope artifact union)")
            )
    schemaAction =
        putStrLn $ T.unpack $ schemaUnion artifacts

    renderCmd =
        command
            "render"
            ( info
                (renderAction <$> optional artifactOpt)
                (progDesc "Render static Dhall artifact examples from the reusable vocabulary")
            )
    artifactOpt =
        strOption (long "artifact" <> metavar "NAME" <> help "render only the named artifact")
    renderAction mname = case mname of
        Nothing -> putStr (concatMap renderOne artifacts)
        Just n ->
            case find ((== T.pack n) . artifactName) artifacts of
                Just a -> putStr (renderOne a)
                Nothing ->
                    die $
                        "context render: unknown artifact "
                            ++ show n
                            ++ "; available: "
                            ++ intercalate ", " (map (T.unpack . artifactName) artifacts)
    renderOne a = T.unpack (artifactName a) <> ":\n" <> T.unpack (renderText a) <> "\n\n"
    inspectCmd =
        command
            "inspect"
            ( info
                (pure runInspect)
                (progDesc "Render the lift composition with the current frame highlighted (read-only)")
            )
    runInspect = do
        path <- siblingProjectConfigPath (T.pack progName)
        cfg <- readContextConfig path
        putStr (Context.renderComposition (cfgContext cfg))
    -- Read-only guarded decode for the @context@ introspection subcommands.
    -- Unlike the gated command path ('loadSiblingProjectConfig'), @context@
    -- introspects ANY sibling <project>.dhall uniformly, so this guards the read
    -- (missing / unreadable / ill-typed) with a one-line diagnostic instead of a
    -- raw backtrace, and imposes no command-class gate.
    readContextConfig path = do
        exists <- doesFileExist path
        unless exists (die ("context: no config at " ++ path))
        decoded <- try (decodeProjectCodecFile codec path)
        case decoded of
            Left (e :: SomeException) ->
                die ("context: failed to decode " ++ path ++ ": " ++ takeWhile (/= '\n') (show e))
            Right cfg -> pure cfg

{- | The @init@ parser shared by @project init@ (§ Y) and @service init@ (§ AA):
write a project-local @<project>.dhall@ without requiring an existing config (a
bootstrap entrypoint). @defaultRole@ selects the role the generated config
declares when @--role@ is not given (@host-orchestrator@ for @project init@,
@cluster-service@ for @service init@). The flags carry **no** core default values
(the project's Production assembly supplies every omitted default), so the
parser yields a defaultless 'InitArgs' which the single assembler interprets.
Python does not trigger this
surface; it builds the host-native binary and execs it (§ M).
-}
initParserInfo ::
    forall cfg configScope specDigest.
    ProjectCodec configScope specDigest cfg ->
    String ->
    String ->
    String ->
    (InitArgs -> IO (cfg configScope)) ->
    ParserInfo (IO ())
initParserInfo codec progName commandLabel defaultRole initBuilder =
    info
        ( initAction
            <$> optional outputOpt
            <*> roleOpt
            <*> optional initSourceRootOpt
            <*> optional dockerfileOpt
            <*> optional initCpuOpt
            <*> optional memoryOpt
            <*> optional storageOpt
            <*> optional haReplicasOpt
            <*> switch (long "force" <> help "overwrite OUTPUT when it already exists")
            <*> switch (long "if-missing" <> help "no-op when OUTPUT already exists (idempotent ensure)")
            <*> many alsoRoleOpt
        )
        (progDesc "Write a project-local <project>.dhall without requiring an existing config")
  where
    initAction moutput roleName mroot mDockerfile mcpu mMemory mStorage mha forceFlag ifMissingFlag alsoRolesRaw = do
        roleKind <- either die pure (parseConfigRole roleName)
        -- A config may declare more than one role (§ X): the primary --role plus
        -- any --also-role grants (e.g. a project authority that is also a service
        -- authority). Each grant unions the role's command classes + capabilities.
        extraRoles <- mapM (either die pure . parseConfigRole) alsoRolesRaw
        let args =
                InitArgs
                    { role = roleKind
                    , alsoRoles = extraRoles
                    , output = moutput
                    , sourceRoot = mroot
                    , mCpu = mcpu
                    , memory = T.pack <$> mMemory
                    , storage = T.pack <$> mStorage
                    , dockerfile = T.pack <$> mDockerfile
                    , haReplicas = mha
                    , force = forceFlag
                    , ifMissing = ifMissingFlag
                    }
        cfg <- initBuilder args
        outPath <- maybe defaultProjectConfigPath pure moutput
        exists <- doesFileExist outPath
        if exists && ifMissingFlag && not forceFlag
            then putStrLn (commandLabel ++ ": " ++ outPath ++ " already present")
            else do
                when (exists && not forceFlag) $
                    die (commandLabel ++ ": " ++ outPath ++ " already exists (pass --force to overwrite)")
                writeScopedProjectConfigFile codec outPath cfg
    defaultProjectConfigPath = do
        exe <- getExecutablePath
        pure (takeDirectory exe </> progName ++ ".dhall")
    outputOpt =
        strOption
            ( long "output"
                <> short 'o'
                <> metavar "FILE"
                <> help "path to write; defaults to the executable sibling <project>.dhall"
            )
    roleOpt =
        strOption
            ( long "role"
                <> metavar "ROLE"
                <> value defaultRole
                <> showDefault
                <> help ("local role (" ++ T.unpack (T.intercalate (T.pack ", ") configRoleNames) ++ ")")
            )
    alsoRoleOpt =
        strOption
            ( long "also-role"
                <> metavar "ROLE"
                <> help "grant an additional role's authority to this config (repeatable; a multi-role config, see X)"
            )
    dockerfileOpt =
        strOption
            ( long "dockerfile"
                <> metavar "PATH"
                <> help "project Dockerfile path recorded in the generated config (project default when omitted)"
            )
    initSourceRootOpt =
        strOption
            ( long "source-root"
                <> metavar "DIR"
                <> help "source root recorded in the generated context; defaults to the current directory"
            )
    initCpuOpt =
        option auto (long "cpu" <> metavar "N" <> help "CPU resource budget (project default when omitted)") :: Parser Natural
    memoryOpt =
        strOption
            ( long "memory"
                <> metavar "TEXT"
                <> help "memory resource budget (project default when omitted)"
            )
    storageOpt =
        strOption
            ( long "storage"
                <> metavar "TEXT"
                <> help "storage resource budget (project default when omitted)"
            )
    haReplicasOpt =
        option auto (long "ha-replicas" <> metavar "N" <> help "HA replica count recorded in deploy settings (project default when omitted)") :: Parser Natural

{- | The @project@ lifecycle command (§ Y): @init@ writes the root config, then
the recursive interpreter brings the chain @up@ / @down@ / @destroy@. @project up
--dry-run@ renders the pure @chain cfg@ plan (the single representation, § W);
@project up@ interprets it recursively from the current frame; @project down@
stops service/VM frames and tears down kind clusters, removing no filesystem path
(the teardown removal set is empty); @project destroy@ also deletes everything the
chain provisioned — for a VM-backed project, the provider VM and its disk. Cluster
teardown never enumerates the plan's @.data@ path for removal, which is the whole
of the never-delete-@.data@ invariant: it is not host mirroring, and the path
still lives inside whatever frame @destroy@ deletes.
-}
projectCommandGroup ::
    forall projectId cfg specDigest.
    (ProjectCfg cfg) =>
    Authority.InstalledProjectIdentity projectId ->
    FinalizedProjectSpec (V.Production projectId) specDigest cfg ->
    String ->
    (InitArgs -> IO (cfg (V.Production projectId))) ->
    Mod CommandFields (IO ())
projectCommandGroup project finalizedSpec progName initBuilder =
    command
        "project"
        ( info
            (hsubparser (pInit <> pUp <> pDown <> pDestroy))
            (progDesc "Project lifecycle: init the root config, then interpret the chain (up/down/destroy)")
        )
  where
    codec = finalizedProjectCodec finalizedSpec
    pInit = command "init" (initParserInfo codec progName "project init" "host-orchestrator" initBuilder)
    pUp =
        command
            "up"
            ( info
                (runUp <$> switch (long "dry-run" <> help "render the chain plan without acting"))
                (progDesc "Interpret the chain from the current frame (idempotent); --dry-run renders the plan")
            )
    pDown =
        command
            "down"
            (info (pure runDown) (progDesc "Stop service/VM frames and tear down kind clusters; remove no filesystem path"))
    pDestroy =
        command
            "destroy"
            (info (pure runDestroy) (progDesc "Stop then delete everything the chain provisioned, including any provider VM and its disk"))

    -- @project up@ is the recursive interpreter that runs in EVERY orchestration
    -- frame (host → VM → container), so it gates as 'ClusterLifecycleCommand',
    -- which is permitted in the three orchestration kinds (HostOrchestrator /
    -- VMOrchestrator / VMProjectContainer) plus the TestHarness kind, and
    -- rejected in the ClusterService / Daemon / OneShotJob / ImageBuildContainer
    -- leaves, where a recursive @project up@ must not run (§ X).
    --
    -- The sibling is read and admitted **once** here (§ 15.9). Plan
    -- construction and every step the plan runs consume that one
    -- 'ValidatedConfig' snapshot, so replacing @<project>.dhall@ mid-run cannot
    -- change what the running chain executes.
    runUp dryRun =
        withSiblingValidatedProjectConfigRoot codec (T.pack progName) Context.ClusterLifecycleCommand [] $ \_wire validated ctx root -> do
            unless (null (Context.parentChain ctx)) $
                die "project up: authenticated recursive child admission is not yet available"
            store <- openAuthorityStore root
            recovered <-
                withRecoveredProductionPlan store root validated ctx $ \recoveredSpec rootAuthority _modeLease lease verified bound binding plan current _frame admittedContext ->
                    if dryRun
                        then putStr (renderChain plan)
                        else do
                            lifecycle <-
                                LifecycleContext.withValidatedLifecycleContext
                                    root
                                    store
                                    plan
                                    (validatedContextValue admittedContext)
                                    ( \validatedLifecycle -> do
                                        cfg <- hostConfig
                                        self <- currentSelfRef ("/usr/local/bin/" ++ progName)
                                        runBoundProjectUp
                                            root
                                            cfg
                                            self
                                            recoveredSpec
                                            rootAuthority
                                            lease
                                            verified
                                            bound
                                            binding
                                            plan
                                            current
                                            (validatedContextValue admittedContext)
                                            validatedLifecycle
                                    )
                            either
                                (die . LifecycleContext.lifecycleContextErrorMessage)
                                pure
                                lifecycle
            case recovered of
                Right () -> pure ()
                Left failure
                    | startsFreshProductionInvocation failure ->
                        withFreshProductionPlan store root validated ctx Authority.ProjectUp $ \productionRoot plan current _frame admittedContext ->
                            if dryRun
                                then putStr (renderChain plan)
                                else do
                                    let rootAuthority = productionRootAuthority productionRoot
                                        unbound = productionRootUnboundLease productionRoot
                                    lifecycle <-
                                        LifecycleContext.withValidatedLifecycleContext
                                            root
                                            store
                                            plan
                                            (validatedContextValue admittedContext)
                                            ( \validatedLifecycle -> do
                                                cfg <- hostConfig
                                                self <- currentSelfRef ("/usr/local/bin/" ++ progName)
                                                persisted <-
                                                    withPersistedPlanSnapshot
                                                        rootAuthority
                                                        unbound
                                                        plan
                                                        ( \verified bound binding lease _normalRecovery ->
                                                            runBoundProjectUp
                                                                root
                                                                cfg
                                                                self
                                                                finalizedSpec
                                                                rootAuthority
                                                                lease
                                                                verified
                                                                bound
                                                                binding
                                                                plan
                                                                current
                                                                (validatedContextValue admittedContext)
                                                                validatedLifecycle
                                                        )
                                                either (die . ("project snapshot: " ++) . show) pure persisted
                                            )
                                    either
                                        (die . LifecycleContext.lifecycleContextErrorMessage)
                                        pure
                                        lifecycle
                Left failure -> die ("project snapshot: " ++ show failure)
    {- Run the best-effort `destroy` reverse projection at the root frame, then
    die. It is the *same* projection `project destroy` runs — one representation
    (§ W) — so a failed `project up` cannot leak resources a real destroy would
    have released. Best-effort: the whole unwind must not hinge on one node, and
    the run is failing already, so a failure here is announced and swallowed
    rather than replacing the chain's own cause.
    -}
    failChain ::
        forall rootId spec planId configId frame.
        ProjectPlan (V.Production projectId) spec planId configId cfg ->
        CurrentFrame (V.Production projectId) planId frame ->
        CanonicalProjectRoot (V.Production projectId) rootId ->
        HostConfig ->
        Context.BinaryContext ->
        String ->
        IO ()
    failChain plan current root cfg ctx reason = do
        when (null (Context.parentChain ctx)) $ do
            putStrLn "project up: chain failed — running best-effort teardown (project destroy) so the VM/cluster/.wslconfig are not leaked"
            ignoreChainExc (reverseProjection plan current root ctx cfg Authority.ProjectDestroy)
        die reason
    -- Swallow a teardown step's exception (best-effort): the whole teardown must not
    -- hinge on one step succeeding.
    ignoreChainExc act = do
        r <- try act
        case (r :: Either SomeException ()) of
            Right () -> pure ()
            Left e -> putStrLn ("  (teardown step skipped: " ++ show e ++ ")")

    runDown =
        withSiblingValidatedProjectConfigRoot codec (T.pack progName) Context.HostOrchestratorCommand [] $ \_wire validated ctx root -> do
            unless (null (Context.parentChain ctx)) $
                die "project down: authenticated recursive child admission is not yet available"
            cfg <- hostConfig
            runProductionTeardown
                root
                validated
                ctx
                cfg
                Authority.ProjectDown
    runDestroy =
        withSiblingValidatedProjectConfigRoot codec (T.pack progName) Context.HostOrchestratorCommand [] $ \_wire validated ctx root -> do
            unless (null (Context.parentChain ctx)) $
                die "project destroy: authenticated recursive child admission is not yet available"
            cfg <- hostConfig
            runProductionTeardown
                root
                validated
                ctx
                cfg
                Authority.ProjectDestroy

    {- | Admit the sole fresh Production plan for one command invocation.

    The Production root, lifecycle profile, draft stream, exact plan, and
    current-frame evidence are opened in that order.  The one 'withProjectPlan'
    site is deliberately private to this helper, so a command body cannot mint
    another local plan identity after receiving the first one.
    -}
    withFreshProductionPlan ::
        forall rootId configId verb result.
        ProtectedStore ->
        CanonicalProjectRoot (V.Production projectId) rootId ->
        ValidatedConfig
            (V.Production projectId)
            specDigest
            configId
            (cfg (V.Production projectId)) ->
        Context.BinaryContext ->
        Authority.ProjectVerb verb ->
        ( forall brokerGeneration planId frame.
          ProductionRoot projectId brokerGeneration verb ->
          ProjectPlan
            (V.Production projectId)
            specDigest
            planId
            configId
            cfg ->
          CurrentFrame (V.Production projectId) planId frame ->
          ProjectFrame
            (V.Production projectId)
            specDigest
            planId
            configId
            frame ->
          ValidatedContext (V.Production projectId) planId frame ->
          IO result
        ) ->
        IO result
    withFreshProductionPlan store root validated ctx verb use = do
        opened <-
            withProductionRoot store project verb $ \productionRoot -> do
                let rootAuthority = productionRootAuthority productionRoot
                    unbound = productionRootUnboundLease productionRoot
                profiled <-
                    withProductionLifecycleProfile
                        (Authority.rootScopeAuthority rootAuthority)
                        (productionActiveMode (productionRootModeLease productionRoot))
                        unbound
                        ( \profile -> do
                            drafts <-
                                either
                                    (die . ("project plan: " ++) . show)
                                    pure
                                    (projectPlanDrafts finalizedSpec root validated)
                            planAction <-
                                either
                                    (die . ("project plan: " ++) . show)
                                    pure
                                    ( withProjectPlan
                                        profile
                                        root
                                        validated
                                        drafts
                                        ( \plan ->
                                            case withCurrentFrame plan ctx (use productionRoot plan) of
                                                Left failure -> die ("project frame: " ++ show failure)
                                                Right admittedAction -> admittedAction
                                        )
                                    )
                            planAction
                        )
                case profiled of
                    Left failure -> pure (Left (ModeAuthorityFailure failure))
                    Right admittedAction -> Right <$> admittedAction
        either (die . T.unpack . modeErrorMessage) pure opened

    {- | Reconstruct the sole local plan identity named by an existing bound
    Production invocation.

    Snapshot admission owns the @planId@ quantifier.  Profile refinement,
    candidate-spec/config alignment, reconstruction, current-frame admission,
    and the consumer all remain beneath that same binder.
    -}
    withRecoveredProductionPlan ::
        forall rootId configId result.
        ProtectedStore ->
        CanonicalProjectRoot (V.Production projectId) rootId ->
        ValidatedConfig
            (V.Production projectId)
            specDigest
            configId
            (cfg (V.Production projectId)) ->
        Context.BinaryContext ->
        ( forall brokerGeneration recoveredSpecDigest planDigest planId frame.
          FinalizedProjectSpec
            (V.Production projectId)
            recoveredSpecDigest
            cfg ->
          Authority.RootInvocationAuthority
            (V.Production projectId)
            brokerGeneration
            Authority.VerbUp ->
          ProjectModeLease projectId ProductionMode brokerGeneration ->
          BoundRunLease
            (V.Production projectId)
            recoveredSpecDigest
            planDigest
            brokerGeneration ->
          VerifiedPlanSnapshot
            (V.Production projectId)
            recoveredSpecDigest
            planDigest ->
          BoundPlanSnapshot
            (V.Production projectId)
            recoveredSpecDigest
            planDigest
            planId ->
          PlanDigestBinding
            (V.Production projectId)
            recoveredSpecDigest
            planDigest
            planId ->
          ProjectPlan
            (V.Production projectId)
            recoveredSpecDigest
            planId
            configId
            cfg ->
          CurrentFrame (V.Production projectId) planId frame ->
          ProjectFrame
            (V.Production projectId)
            recoveredSpecDigest
            planId
            configId
            frame ->
          ValidatedContext (V.Production projectId) planId frame ->
          IO result
        ) ->
        IO (Either SnapshotError result)
    withRecoveredProductionPlan store root candidateConfig ctx use =
        withBoundPlanSnapshot
            store
            project
            ( \closeKey ->
                die
                    ( "project recovery: the prior Production invocation has a terminal acknowledgment "
                        ++ show closeKey
                        ++ "; terminal close recovery is required"
                    )
            )
            ( \rootAuthority modeLease lease verified bound binding recovery -> do
                profiledAction <-
                    either
                        (die . T.unpack . modeErrorMessage)
                        pure
                        ( withRecoveredProductionLifecycleProfile
                            rootAuthority
                            modeLease
                            lease
                            verified
                            bound
                            binding
                            recovery
                            ( \profile -> do
                                inputsAction <-
                                    either
                                        (die . ("project recovery: " ++) . show)
                                        pure
                                        ( withRecoveredProductionProjectPlanInputs
                                            profile
                                            root
                                            finalizedSpec
                                            candidateConfig
                                            ( \recoveredSpec recoveredConfig recoveredDrafts -> do
                                                planAction <-
                                                    either
                                                        (die . ("project recovery: " ++) . show)
                                                        pure
                                                        ( withRecoveredProductionProjectPlan
                                                            profile
                                                            root
                                                            verified
                                                            bound
                                                            binding
                                                            recoveredConfig
                                                            recoveredDrafts
                                                            ( \plan ->
                                                                case withCurrentFrame plan ctx (use recoveredSpec rootAuthority modeLease lease verified bound binding plan) of
                                                                    Left failure -> die ("project frame: " ++ show failure)
                                                                    Right admittedAction -> admittedAction
                                                            )
                                                        )
                                                planAction
                                            )
                                        )
                                inputsAction
                            )
                        )
                profiledAction
            )

    -- Only a genuinely new store or an exactly retained unbound retry may
    -- enter the fresh branch.  Every corruption, immutable-snapshot conflict,
    -- wrong mode, missing lease, terminal state, or store failure stays fatal.
    startsFreshProductionInvocation :: SnapshotError -> Bool
    startsFreshProductionInvocation failure = case failure of
        SnapshotVerificationError (ModeWrongMode "production" "absent") -> True
        SnapshotVerificationError (ModeLeaseNotBindable "production" "unbound") -> True
        _ -> False

    {- | Run one already bound exact Production @up@ invocation.

    Journal, frame cursor, authority, Chain, and the final Execute-to-Teardown
    transition all consume the same plan identity.  A recovered Teardown cursor
    means this invocation's current-frame interpretation already completed.
    -}
    runBoundProjectUp ::
        forall rootId brokerGeneration exactSpecDigest planDigest planId configId failureFrame entryFrame.
        CanonicalProjectRoot (V.Production projectId) rootId ->
        HostConfig ->
        SelfRef ->
        FinalizedProjectSpec
            (V.Production projectId)
            exactSpecDigest
            cfg ->
        Authority.RootInvocationAuthority
            (V.Production projectId)
            brokerGeneration
            Authority.VerbUp ->
        BoundRunLease
            (V.Production projectId)
            exactSpecDigest
            planDigest
            brokerGeneration ->
        VerifiedPlanSnapshot
            (V.Production projectId)
            exactSpecDigest
            planDigest ->
        BoundPlanSnapshot
            (V.Production projectId)
            exactSpecDigest
            planDigest
            planId ->
        PlanDigestBinding
            (V.Production projectId)
            exactSpecDigest
            planDigest
            planId ->
        ProjectPlan
            (V.Production projectId)
            exactSpecDigest
            planId
            configId
            cfg ->
        CurrentFrame (V.Production projectId) planId failureFrame ->
        Context.BinaryContext ->
        LifecycleContext.ValidatedLifecycleContext
            (V.Production projectId)
            exactSpecDigest
            planId
            configId
            entryFrame ->
        IO ()
    runBoundProjectUp root cfg self exactSpec rootAuthority lease verified bound binding plan current admittedContext lifecycleContext = do
        -- The shared @exactSpecDigest@ index already fixes which finalized
        -- specification may be threaded here.  This is that agreement's runtime
        -- witness, and it is the digest the root catalog manifest is keyed by,
        -- so a recovered index that reached this entry without its own
        -- digest-proven relabelling is refused before any lifecycle effect.
        unless
            ( projectCodecSpecDigest (finalizedProjectCodec exactSpec)
                == planSnapshotSpecDigest verified
            )
            (die "project up: the finalized specification is not the bound plan snapshot's")
        ran <-
            runExactProjectUp
                cfg
                self
                exactSpec
                rootAuthority
                lease
                verified
                bound
                binding
                plan
                lifecycleContext
        case ran of
            Right () -> pure ()
            Left err
                | safetyRefusalMarker `isInfixOf` err -> die err
                | otherwise ->
                    failChain
                        plan
                        current
                        root
                        cfg
                        admittedContext
                        err

    runProductionTeardown ::
        forall rootId configId verb.
        CanonicalProjectRoot (V.Production projectId) rootId ->
        ValidatedConfig
            (V.Production projectId)
            specDigest
            configId
            (cfg (V.Production projectId)) ->
        Context.BinaryContext ->
        HostConfig ->
        Authority.ProjectVerb verb ->
        IO ()
    runProductionTeardown root validated ctx cfg verb = do
        store <- openAuthorityStore root
        recovered <-
            withRecoveredProductionPlan store root validated ctx $ \_ _ _ _ _ _ _ plan current _ _ ->
                reverseProjection plan current root ctx cfg verb
        case recovered of
            Right () -> pure ()
            Left failure
                | startsFreshProductionInvocation failure ->
                    withFreshProductionPlan store root validated ctx verb $ \_ plan current _ _ ->
                        reverseProjection plan current root ctx cfg verb
            Left failure -> die ("project snapshot: " ++ show failure)

    {- Run the verb's reverse projection of the same validated plan (§ W).

    @down@ and @destroy@ are not two hand-written cleanup routines: each is
    'Teardown.teardownPlan' applied to this plan and its verb, driven deepest
    frame first. Every effect is a node of that plan — the reverse its own step
    declared with 'Step.reversedBy' — except a @CoreManagedReverse@ node that
    declared none, which the core's own cluster adapter releases. A
    @PreserveOnReverse@ step (the durable host root) never enters either
    projection at all, which is the whole of the never-delete-@.data@ invariant.
    -}
    reverseProjection ::
        forall rootId spec planId configId frame verb.
        ProjectPlan (V.Production projectId) spec planId configId cfg ->
        CurrentFrame (V.Production projectId) planId frame ->
        CanonicalProjectRoot (V.Production projectId) rootId ->
        Context.BinaryContext ->
        HostConfig ->
        Authority.ProjectVerb verb ->
        IO ()
    reverseProjection plan currentFrame root ctx cfg verb = do
        let projection = Teardown.teardownPlan plan currentFrame verb
        self <- currentSelfRef ("/usr/local/bin/" ++ progName)
        descended <- newIORef Nothing
        let current = currentFrameId currentFrame
        case Teardown.openTeardownForest projection of
            Left err -> die ("project teardown: " ++ Teardown.teardownErrorMessage err)
            Right opened -> do
                {- The forest drives itself: the child-first ordering and the
                destroy-only pre-descent reachability step are its, not this
                call site's. This supplies only the effect for one offered
                node and the row for its outcome. -}
                driven <-
                    Teardown.driveTeardownForest
                        opened
                        (\_ -> descendCurrent self descended current)
                        (\_ -> ordinaryReverse)
                        (\_ -> descentReverse self descended current)
                        announce
                case driven of
                    Left outstanding ->
                        die
                            ( "project teardown attempted every reverse step but "
                                ++ "these nodes did not settle:\n"
                                ++ unlines (map (("  - " ++) . T.unpack) outstanding)
                            )
                    -- Frame-bound settlement is minted from the completed
                    -- forest, never from the fact that the verb returned.
                    -- Project-wide destroy is a second, root-only refinement.
                    Right completed ->
                        case Teardown.verifySubtreeSettled projection completed of
                            Left err ->
                                die ("project teardown: " ++ Teardown.teardownErrorMessage err)
                            Right subtree ->
                                case Teardown.settledDestroyEvidence plan currentFrame subtree of
                                    Nothing -> announceSubtree subtree
                                    Just (Left (Teardown.TeardownRootFrameMismatch _ _)) ->
                                        -- A nested command returns after settling its
                                        -- own exact subtree. Only the root can promote
                                        -- that proof to project-wide closure.
                                        announceSubtree subtree
                                    Just (Left err) ->
                                        die ("project teardown: " ++ Teardown.teardownErrorMessage err)
                                    Just (Right settled) ->
                                        putStrLn
                                            ( "project teardown: settled root destroy with "
                                                ++ show
                                                    ( length
                                                        ( Teardown.destroySettledTerminalObservations
                                                            settled
                                                        )
                                                    )
                                                ++ " terminal observations of plan "
                                                ++ T.unpack (Teardown.destroySettledPlanDigest settled)
                                            )
      where
        announceSubtree subtree =
            putStrLn
                ( "project teardown: settled frame "
                    ++ T.unpack (Teardown.subtreeSettledOpeningFrame subtree)
                    ++ " with "
                    ++ show
                        (length (Teardown.subtreeSettledTerminalObservations subtree))
                    ++ " terminal observations"
                )

        {- One ordinary node's attempt.

        Only a 'LocalWork' can enter this runner. A node of a deeper frame is
        represented by the disjoint descent branch and therefore cannot reach
        a declared reverse or the core adapter in this process.
        -}
        ordinaryReverse ::
            Teardown.LocalWork (V.Production projectId) planId frame verb ->
            IO Step.TeardownOutcome
        ordinaryReverse local =
            case (Teardown.localWorkRun local, Teardown.localWorkPolicy local) of
                (Just declared, _) ->
                    guardedReverse (declared cfg (Teardown.localWorkAction local))
                (Nothing, Step.CoreManagedReverse) ->
                    guardedReverse
                        ( coreManaged
                            (Teardown.localWorkKey local)
                            (Teardown.localWorkAction local)
                        )
                (Nothing, _) ->
                    pure
                        ( Step.TeardownForeignRetained
                            "the node acquired nothing this frame must release"
                        )

        {- Invoke this verb in the next frame, at most once per run.

        The descent context is the plan's own — the same node that announced the
        child on the way down — so the reverse crosses exactly the boundary the
        forward pass crossed. Every node of every deeper frame is settled by that
        one invocation, because the child binary runs the same forest over its own
        segment and recurses further itself.
        -}
        descentReverse ::
            forall childFrame.
            SelfRef ->
            IORef (Maybe Step.TeardownOutcome) ->
            T.Text ->
            Teardown.DescentWork
                (V.Production projectId)
                planId
                frame
                childFrame
                verb ->
            IO
                ( Either
                    T.Text
                    ( Teardown.SubtreeSettled
                        (V.Production projectId)
                        planId
                        childFrame
                        verb
                    )
                )
        descentReverse self descended current descent
            | Teardown.descentWorkParentFrame descent /= current =
                pure (Left (invalidDescentDetail "the descent parent is not this opening frame"))
            | otherwise =
                Teardown.withDescentWorkSubtree descent $ \childProjection ->
                    if
                        Teardown.teardownPlanFrameId childProjection
                            /= Teardown.descentWorkChildFrame descent
                        then
                            pure
                                ( Left
                                    ( invalidDescentDetail
                                        "the retained child projection does not match the descent edge"
                                    )
                                )
                        else do
                            raw <-
                                descendOnce
                                    self
                                    descended
                                    (Teardown.descentWorkParentFrame descent)
                                    (Teardown.descentWorkChildFrame descent)
                            pure
                                ( Left
                                    ( rawChildProofRefusal
                                        (Teardown.descentWorkChildFrame descent)
                                        raw
                                    )
                                )

        descendCurrent self descended current = case nextFrameAfter (topology plan) current of
            Nothing ->
                pure
                    ( Step.TeardownForeignRetained
                        "this frame is the innermost one the chain enters"
                    )
            Just (nextFrame, _) -> descendOnce self descended current nextFrame

        descendOnce self descended parent child =
            case nextFrameAfter (topology plan) parent of
                Just (nextFrame, nextCtx)
                    | nextFrame == child -> do
                        already <- readIORef descended
                        case already of
                            Just outcome -> pure outcome
                            Nothing -> do
                                outcome <- runDescent self nextFrame nextCtx
                                writeIORef descended (Just outcome)
                                pure outcome
                _ -> pure (invalidDescent "the descent child is not the topology's immediate edge")

        invalidDescent detail =
            Step.TeardownFailed ("plan-bound teardown descent mismatch: " ++ detail)

        invalidDescentDetail detail =
            "plan-bound teardown descent mismatch: " <> T.pack detail

        rawChildProofRefusal child outcome =
            "child frame "
                <> child
                <> " returned only an untyped recursive outcome ("
                <> T.pack (show outcome)
                <> "); an exact SubtreeSettled proof is required"

        runDescent self nextFrame nextCtx = do
            putStrLn
                ( "project teardown: descending into "
                    ++ T.unpack nextFrame
                    ++ " to run its own reverse steps first"
                )
            result <-
                liftSubcommandWithStdin
                    cfg
                    self
                    nextCtx
                    ["project", T.unpack (Authority.projectVerbName verb)]
                    (liftStdin nextCtx)
            case result of
                Right (ExitSuccess, out, _) ->
                    putStr out >> pure Step.TeardownReleased
                Right (_, out, err) ->
                    putStr out >> pure (Step.TeardownFailed err)
                Left err -> pure (Step.TeardownFailed err)

        guardedReverse effect = do
            attempted <- try effect
            pure $ case attempted of
                Right outcome -> outcome
                Left exc -> Step.TeardownFailed (displayException (exc :: SomeException))

        {- The one resource the core releases itself is the kind cluster, and
        only from the frame that owns the `deploy-kind` step: the kube tools live
        in the cluster-bearing project container, not on every host frame. A
        nested cluster is instead released with its provider frame, or by a
        reverse the project declares on that node (the direct Linux GPU lane does
        exactly that). Reporting the other case as retained rather than released
        keeps the distinction visible instead of treating expected host-side tool
        absence as cleanup.

        The action selects, not the frame alone: `deploy-chart` and
        `expose-port` are core-managed too, but they are *inside* the cluster
        and have no separate backend call — deleting the cluster removes the
        Helm release and the NodePort with it. Handing them to the cluster
        adapter would run the cluster teardown once per node.
        -}
        coreManaged _key reverseAction = case reverseAction of
            Step.DeleteCluster
                | currentFrameOwnsCluster ctx plan -> do
                    case clusterEffectFor verb of
                        Nothing ->
                            pure
                                ( Step.TeardownFailed
                                    "project up cannot execute reverse cluster work"
                                )
                        Just clusterEffect -> do
                            withCurrentDirectory
                                (canonicalProjectRootPath root)
                                (clusterEffect (planForRoot root ctx))
                            pure Step.TeardownReleased
                | otherwise ->
                    pure
                        ( Step.TeardownForeignRetained
                            ( "cluster is owned by a different chain frame; skipping kind cleanup in "
                                ++ T.unpack (Context.currentFrame ctx)
                            )
                        )
            _ -> pure (Step.TeardownForeignRetained "released with the cluster that contains it")

        clusterEffectFor selected = case selected of
            Authority.ProjectUp -> Nothing
            Authority.ProjectDown -> Just (clusterDown cfg)
            Authority.ProjectDestroy -> Just (clusterDelete cfg)

    {- One structured row per node of the reverse projection (§ Y). The five
    outcomes stay distinct because an operator resolves them differently, and
    because the test harness's report card consumes exactly these rows. -}
    announce key outcome = case outcome of
        Step.TeardownReleased -> putStrLn ("project teardown: released " ++ T.unpack key)
        Step.TeardownForeignRetained detail ->
            putStrLn ("project teardown: retained " ++ T.unpack key ++ " — " ++ detail)
        Step.TeardownRefused detail ->
            putStrLn ("project teardown: refused " ++ T.unpack key ++ " — " ++ detail)
        Step.TeardownFailed detail ->
            putStrLn ("project teardown: FAILED " ++ T.unpack key ++ " — " ++ detail)

    {- The project's own protected authority store, under the canonical root
    (§ X) rather than the caller's working directory.

    It is keyed by the **installed project name** as well as the root, because a
    single project root can legitimately host more than one installed binary —
    this repository hosts both @hostbootstrap@ and @hostbootstrap-demo@ — and
    each is a distinct installed project with its own broker generations and
    invocation records. 'Authority.withVerifiedRootInvocation' still refuses a
    store whose recorded project is not this one, so a directory copied under
    another name is caught.
    -}
    openAuthorityStore ::
        forall rootScope rootId. CanonicalProjectRoot rootScope rootId -> IO ProtectedStore
    openAuthorityStore root = do
        opened <-
            openProtectedStore
                ( canonicalProjectRootPath root
                    </> ".hostbootstrap"
                    </> "authority"
                    </> T.unpack (Authority.installedProjectName project)
                )
        either (dieAuthority . T.unpack . protectedErrorMessage) pure opened

    dieAuthority :: String -> IO a
    dieAuthority reason = die ("project: " ++ reason)

{- | Run the exact current-frame @up@ transaction shared by Production and
Harness command dispatch.

The returned failure is still descriptive rather than authorizing.  Callers
decide whether it is a Production command failure or a Harness report outcome;
neither can replace any of the indexed evidence consumed here.
-}
runExactProjectUp ::
    forall scope specDigest planDigest planId configId cfg frame brokerGeneration.
    (ProjectCfg cfg) =>
    HostConfig ->
    SelfRef ->
    FinalizedProjectSpec scope specDigest cfg ->
    Authority.RootInvocationAuthority scope brokerGeneration Authority.VerbUp ->
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    VerifiedPlanSnapshot scope specDigest planDigest ->
    BoundPlanSnapshot scope specDigest planDigest planId ->
    PlanDigestBinding scope specDigest planDigest planId ->
    ProjectPlan scope specDigest planId configId cfg ->
    LifecycleContext.ValidatedLifecycleContext scope specDigest planId configId frame ->
    IO (Either String ())
runExactProjectUp cfg self exactSpec rootAuthority lease verified bound binding plan lifecycleContext =
    withRootProjectUpLifecycleEntry
        exactSpec
        rootAuthority
        Authority.ProjectUp
        verified
        bound
        binding
        lease
        plan
        lifecycleContext
        (runRootProjectUpLifecycleEntry cfg self)

{- | Drive one exact Harness destroy projection and return its settled proof.

The plan/current-frame pair is the same pair retained by the generated-config
bracket.  Production's verb-polymorphic wrapper and this Harness-only wrapper
both consume the public teardown forest; neither accepts a second plan digest,
frame name, or cleanup list.
-}
runExactDestroyProjection ::
    forall scope specDigest planId configId cfg frame rootId.
    String ->
    ProjectPlan scope specDigest planId configId cfg ->
    CurrentFrame scope planId frame ->
    CanonicalProjectRoot scope rootId ->
    Context.BinaryContext ->
    HostConfig ->
    IO (Teardown.DestroySettled scope planId)
runExactDestroyProjection progName plan currentFrame root ctx cfg = do
    let projection = Teardown.teardownPlan plan currentFrame verb
    self <- currentSelfRef ("/usr/local/bin/" ++ progName)
    descended <- newIORef Nothing
    let current = currentFrameId currentFrame
    opened <-
        either
            (die . ("project teardown: " ++) . Teardown.teardownErrorMessage)
            pure
            (Teardown.openTeardownForest projection)
    driven <-
        Teardown.driveTeardownForest
            opened
            (\_ -> descendCurrent self descended current)
            (\_ -> ordinaryReverse)
            (\_ -> descentReverse self descended current)
            announce
    completed <-
        either
            ( \outstanding ->
                die
                    ( "project teardown attempted every reverse step but these nodes did not settle:\n"
                        ++ unlines (map (("  - " ++) . T.unpack) outstanding)
                    )
            )
            pure
            driven
    subtree <-
        either
            (die . ("project teardown: " ++) . Teardown.teardownErrorMessage)
            pure
            (Teardown.verifySubtreeSettled projection completed)
    settled <-
        either
            (die . ("project teardown: " ++) . Teardown.teardownErrorMessage)
            pure
            (Teardown.verifyDestroySettled plan currentFrame subtree)
    putStrLn
        ( "project teardown: settled root destroy with "
            ++ show (length (Teardown.destroySettledTerminalObservations settled))
            ++ " terminal observations of plan "
            ++ T.unpack (Teardown.destroySettledPlanDigest settled)
        )
    pure settled
  where
    verb :: Authority.ProjectVerb Authority.VerbDestroy
    verb = Authority.ProjectDestroy

    ordinaryReverse ::
        Teardown.LocalWork scope planId frame Authority.VerbDestroy ->
        IO Step.TeardownOutcome
    ordinaryReverse local =
        case (Teardown.localWorkRun local, Teardown.localWorkPolicy local) of
            (Just declared, _) ->
                guardedReverse (declared cfg (Teardown.localWorkAction local))
            (Nothing, Step.CoreManagedReverse) ->
                guardedReverse
                    ( coreManaged
                        (Teardown.localWorkKey local)
                        (Teardown.localWorkAction local)
                    )
            (Nothing, _) ->
                pure
                    ( Step.TeardownForeignRetained
                        "the node acquired nothing this frame must release"
                    )

    descentReverse ::
        forall childFrame.
        SelfRef ->
        IORef (Maybe Step.TeardownOutcome) ->
        T.Text ->
        Teardown.DescentWork scope planId frame childFrame Authority.VerbDestroy ->
        IO
            ( Either
                T.Text
                ( Teardown.SubtreeSettled
                    scope
                    planId
                    childFrame
                    Authority.VerbDestroy
                )
            )
    descentReverse self descended current descent
        | Teardown.descentWorkParentFrame descent /= current =
            pure (Left (invalidDescentDetail "the descent parent is not this opening frame"))
        | otherwise =
            Teardown.withDescentWorkSubtree descent $ \childProjection ->
                if
                    Teardown.teardownPlanFrameId childProjection
                        /= Teardown.descentWorkChildFrame descent
                    then
                        pure
                            ( Left
                                ( invalidDescentDetail
                                    "the retained child projection does not match the descent edge"
                                )
                            )
                    else do
                        raw <-
                            descendOnce
                                self
                                descended
                                (Teardown.descentWorkParentFrame descent)
                                (Teardown.descentWorkChildFrame descent)
                        pure
                            ( Left
                                ( rawChildProofRefusal
                                    (Teardown.descentWorkChildFrame descent)
                                    raw
                                )
                            )

    descendCurrent self descended current = case nextFrameAfter (topology plan) current of
        Nothing ->
            pure
                ( Step.TeardownForeignRetained
                    "this frame is the innermost one the chain enters"
                )
        Just (nextFrame, _) -> descendOnce self descended current nextFrame

    descendOnce self descended parent child =
        case nextFrameAfter (topology plan) parent of
            Just (nextFrame, nextCtx)
                | nextFrame == child -> do
                    already <- readIORef descended
                    case already of
                        Just outcome -> pure outcome
                        Nothing -> do
                            outcome <- runDescent self nextFrame nextCtx
                            writeIORef descended (Just outcome)
                            pure outcome
            _ -> pure (invalidDescent "the descent child is not the topology's immediate edge")

    invalidDescent detail =
        Step.TeardownFailed ("plan-bound teardown descent mismatch: " ++ detail)

    invalidDescentDetail detail =
        "plan-bound teardown descent mismatch: " <> T.pack detail

    rawChildProofRefusal child outcome =
        "child frame "
            <> child
            <> " returned only an untyped recursive outcome ("
            <> T.pack (show outcome)
            <> "); an exact SubtreeSettled proof is required"

    runDescent self nextFrame nextCtx = do
        putStrLn
            ( "project teardown: descending into "
                ++ T.unpack nextFrame
                ++ " to run its own reverse steps first"
            )
        result <-
            liftSubcommandWithStdin
                cfg
                self
                nextCtx
                ["project", T.unpack (Authority.projectVerbName verb)]
                (liftStdin nextCtx)
        case result of
            Right (ExitSuccess, out, _) ->
                putStr out >> pure Step.TeardownReleased
            Right (_, out, err) ->
                putStr out >> pure (Step.TeardownFailed err)
            Left err -> pure (Step.TeardownFailed err)

    guardedReverse effect = do
        attempted <- try effect
        pure $ case attempted of
            Right outcome -> outcome
            Left exc -> Step.TeardownFailed (displayException (exc :: SomeException))

    coreManaged _key reverseAction = case reverseAction of
        Step.DeleteCluster
            | currentFrameOwnsCluster ctx plan -> do
                withCurrentDirectory
                    (canonicalProjectRootPath root)
                    (clusterDelete cfg (planForRoot root ctx))
                pure Step.TeardownReleased
            | otherwise ->
                pure
                    ( Step.TeardownForeignRetained
                        ( "cluster is owned by a different chain frame; skipping kind cleanup in "
                            ++ T.unpack (Context.currentFrame ctx)
                        )
                    )
        _ -> pure (Step.TeardownForeignRetained "released with the cluster that contains it")

    announce key outcome = case outcome of
        Step.TeardownReleased -> putStrLn ("project teardown: released " ++ T.unpack key)
        Step.TeardownForeignRetained detail ->
            putStrLn ("project teardown: retained " ++ T.unpack key ++ " — " ++ detail)
        Step.TeardownRefused detail ->
            putStrLn ("project teardown: refused " ++ T.unpack key ++ " — " ++ detail)
        Step.TeardownFailed detail ->
            putStrLn ("project teardown: FAILED " ++ T.unpack key ++ " — " ++ detail)

-- | Whether the current binary frame owns the chain's cluster lifecycle step.
currentFrameOwnsCluster ::
    Context.BinaryContext ->
    ProjectPlan scope specDigest planId configId cfg ->
    Bool
currentFrameOwnsCluster ctx plan =
    any ownsKind (forward plan)
  where
    current = Context.currentFrame ctx
    ownsKind step =
        plannedStepFrameId step == current
            && plannedStepIdentity step == CoreStepIdentity DeployKindId

{- | The @service@ lifecycle command (§ AA): the third DSL-driven core command,
for a project's long-running roles (the @HostDaemon@/service run-model). @init@
writes a service-configured @<project>.dhall@; @schema@ prints the service config
schema (the in-scope artifact union, § Q) and the registered variants; @run@
loads the effective project config and runs its selected role. There is **no
@service down@** — a service's
lifetime is owned by its Kubernetes controller and torn down by @project
destroy@ (§ Y).

@service run@ is a **leaf-frame runtime command, never an orchestrator**: the
context gate first requires 'Context.ServiceCommand', then an explicit kind gate
requires an actual @cluster-service@ or @daemon@ leaf. Thus even a multi-role
host/VM/container orchestrator that carries extra service authority — or a missing
config — fails fast. It then reads the variant from the project's
  Dhall-owned service config; an absent/unknown variant or empty registry fails
  fast. There is no variant CLI argument.
-}
serviceCommandGroup ::
    forall cfg configScope specDigest.
    (ProjectCfg cfg) =>
    ProjectCodec configScope specDigest cfg ->
    String ->
    FinalizedServiceRegistry configScope specDigest (cfg configScope) ->
    (InitArgs -> IO (cfg configScope)) ->
    Mod CommandFields (IO ())
serviceCommandGroup codec progName registry initBuilder =
    command
        "service"
        ( info
            (hsubparser (sInit <> sSchema <> sRun))
            (progDesc "Service lifecycle: init the service config, print the schema, run a long-running role")
        )
  where
    sInit = command "init" (initParserInfo codec progName "service init" "cluster-service" initBuilder)
    sSchema =
        command
            "schema"
            ( info
                (pure runSchema)
                (progDesc "Print the registered service variants and the service config schema")
            )
    sRun =
        command
            "run"
            ( info
                (pure runServiceRun)
                (progDesc "Run the config-selected service variant (leaf-frame; needs a service-role config)")
            )
    runSchema = do
        putStrLn "service variants:"
        case finalizedServiceVariantNames registry of
            [] -> putStrLn "  (none registered)"
            names -> mapM_ (\n -> putStrLn ("  " ++ n)) names
        putStrLn ""
        putStrLn "-- full project schema (not a service-role wire)"
        putStrLn (T.unpack (projectCodecSchemaText codec))
        putStrLn ""
        putStrLn (T.unpack (serviceRoleSchemaFamilies registry))
    runServiceRun =
        withSiblingValidatedProjectConfigContext codec (T.pack progName) Context.ServiceCommand [] $ \wire validated serviceCtx -> do
            let projectCfg = validatedConfigValue validated
            unless (Context.contextKind serviceCtx `elem` [Context.ClusterService, Context.Daemon]) $
                die
                    ( "service run: contextKind "
                        ++ show (Context.contextKind serviceCtx)
                        ++ " is not a service leaf; expected ClusterService or Daemon"
                    )
            (identity, declared, serviceAction) <-
                either
                    (die . ("service run: " ++))
                    pure
                    ( withSelectedServiceRequest
                        (verifiedConfigDigest wire)
                        (inspectLocalContext serviceCtx)
                        projectCfg
                        registry
                        ( \selectedIdentity _ _ declaredEffects serviceEffect ->
                            (selectedIdentity, declaredEffects, serviceEffect)
                        )
                    )
            putStrLn ("service run: selected " ++ serviceIdText identity)
            -- The row the registry fixed for this variant. Once the deploy step
            -- installs a signed activation, this is exactly the row
            -- 'authorizeServiceEffects' compares against the placement's signed
            -- ceiling; printing it now means the declaration is observable
            -- before the authorization that will consume it exists.
            putStrLn
                ( "service run: declared effects "
                    ++ renderDeclaredEffects declared
                )
            serviceAction

{- | Render a declared effect row for the operator.

An empty row is spelled out rather than printed as @[]@: "this role declares no
effects" is a real and meaningful declaration — it is the one that drops its
ceiling's lease requirement — and it should not read like missing output.
-}
renderDeclaredEffects :: [RoleEffect] -> String
renderDeclaredEffects [] = "(none)"
renderDeclaredEffects effects =
    intercalate ", " (map (T.unpack . roleEffectName) effects)

hostConfig :: IO HostConfig
hostConfig = do
    detected <- detect
    case detected of
        Left err -> die err
        Right sub -> buildHostConfig sub

-- | A @FILE@ argument defaulting to @<project>.dhall@.
fileArg :: String -> Parser FilePath
fileArg progName =
    strArgument
        ( metavar "FILE"
            <> value (progName ++ ".dhall")
            <> showDefault
            <> help "path to the project-local <project>.dhall"
        )

-- | The production cluster plan, rooted only from canonical admission authority.
planForRoot :: CanonicalProjectRoot scope rootId -> Context.BinaryContext -> ClusterPlan
planForRoot root ctx =
    resolvePlan (T.unpack (Context.project ctx)) (canonicalProjectRootPath root) Production
