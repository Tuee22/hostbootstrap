{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE GADTs #-}
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
)
where

import Control.Exception (SomeException, fromException, mask)
import Control.Exception.Safe (finally, try)
import Control.Monad (unless, when)
import Data.List (find, intercalate, isInfixOf)
import qualified Data.Text as T
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Chain (renderChain, runChainFromFrame)
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
    writeProjectConfigFile,
    writeScopedProjectConfigFile,
 )
import qualified HostBootstrap.Config.Vocab as V
import qualified HostBootstrap.Context as Context
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
    SafetyRefusal (..),
    TestMatrixError (..),
    TestSuite,
    allCasesSelector,
    allPassed,
    caseIdText,
    parseCaseSelector,
    reportCard,
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
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.Lifecycle.Mode (
    LifecycleProfile,
    ModeError (ModeRecoveryRequired),
    RunLeaseBinding (ExistingRunLeaseBinding, FreshRunLeaseBinding),
    bindRunLease,
    harnessRootHarnessAuthority,
    harnessRootModeLease,
    harnessRootRunId,
    harnessRootUnboundLease,
    modeErrorMessage,
    persistPlanSnapshot,
    runIdText,
    verifyPlanSnapshot,
    withHarnessLifecycleProfile,
 )
import HostBootstrap.Lift (currentSelfRef)
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import HostBootstrap.Protected (
    ProtectedSession,
    ProtectedStore,
    openProtectedStore,
    protectedErrorMessage,
    withProtectedEntry,
 )
import HostBootstrap.Reconcile (LifecyclePlan, lifecyclePlanDigest, withLifecyclePlan)
import HostBootstrap.Service (
    FinalizedServiceRegistry,
    finalizedServiceVariantNames,
    serviceIdText,
    serviceRoleSchemaFamilies,
    withSelectedServiceRequest,
 )
import HostBootstrap.Step (StepPlan, StepPlanError, isDeployKindStep, stepsForFrame)
import qualified HostBootstrap.Step as Step
import HostBootstrap.Substrate (detect)
import qualified HostBootstrap.Teardown as Teardown
import Numeric.Natural (Natural)
import Options.Applicative
import System.Directory (doesFileExist, getCurrentDirectory, withCurrentDirectory)
import System.Environment (getExecutablePath)
import System.Exit (die)
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

{- | Module-private live-plan opener. Requiring the scope-matched lifecycle
profile here makes the plan-opening call structurally depend on the exact
active-mode/unbound-lease gate without adding a public construction route.
-}
withProfiledLifecyclePlan ::
    LifecycleProfile scope ->
    ProjectCodec scope specDigest cfg ->
    StepPlan ->
    (forall planId. LifecyclePlan scope planId -> result) ->
    result
withProfiledLifecyclePlan profile codec plan use =
    profile `seq` withLifecyclePlan codec plan use

{- | The core subcommands every @hostbootstrap@-derived binary exposes. The
project's 'TestSuite' is threaded into the inherited @test@ verb so a project's
cases run under @test@ (not a per-noun subcommand). The project's config seams
are threaded in too: @project init@ uses the Production request of the single
restricted assembler, @test init@ writes via 'psTestInit', and @test run@
generates each exact-run-scoped config through the Harness request.
-}
coreCommands ::
    forall projectId cfg tcfg specDigest.
    (ProjectCfg projectId cfg, TestCfg tcfg) =>
    ProjectCodec (V.Production projectId) specDigest cfg ->
    CodecWitness tcfg ->
    String ->
    [ConfigArtifact] ->
    TestSuite ->
    IO () ->
    FinalizedServiceRegistry
        (V.Production projectId)
        specDigest
        (cfg (V.Production projectId)) ->
    ( forall configScope rootScope rootId.
      CanonicalProjectRoot rootScope rootId ->
      cfg configScope ->
      Either StepPlanError StepPlan
    ) ->
    [ConfigInput] ->
    ( forall scope.
      AssemblyRequest projectId tcfg (TestVariant tcfg) scope ->
      ConfigAssembly scope (cfg scope)
    ) ->
    (InitArgs -> IO (cfg (V.Production projectId))) ->
    (InitArgs -> tcfg) ->
    [Mod CommandFields (IO ())]
coreCommands cfgCodec testCodec progName projectArtifacts suite checkCode services stepPlan assemblyInputs assemble initBuilder testInit =
    [ contextCommand @projectId @cfg @(V.Production projectId) cfgCodec progName projectArtifacts initBuilder
    , projectCommandGroup cfgCodec progName stepPlan initBuilder
    , testCommand @projectId @cfg @tcfg cfgCodec testCodec progName suite stepPlan assemblyInputs assemble testInit
    , serviceCommandGroup cfgCodec progName services initBuilder
    , checkCodeCommand @projectId @cfg @(V.Production projectId) cfgCodec progName checkCode
    ]

gate ::
    forall projectId cfg configScope specDigest.
    (ProjectCfg projectId cfg) =>
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
    (ProjectCfg projectId cfg, TestCfg tcfg) =>
    ProjectCodec (V.Production projectId) specDigest cfg ->
    CodecWitness tcfg ->
    String ->
    TestSuite ->
    ( forall configScope rootScope rootId.
      CanonicalProjectRoot rootScope rootId ->
      cfg configScope ->
      Either StepPlanError StepPlan
    ) ->
    [ConfigInput] ->
    ( forall scope.
      AssemblyRequest projectId tcfg (TestVariant tcfg) scope ->
      ConfigAssembly scope (cfg scope)
    ) ->
    (InitArgs -> tcfg) ->
    Mod CommandFields (IO ())
testCommand _productionCodec testCodec progName suite projectPlan assemblyInputs assemble testInit =
    command
        "test"
        ( info
            (hsubparser (testInitCmd <> testRunCmd))
            (progDesc "Test surface: `init` writes <project>.test.dhall; `run` runs a suite against the live stack (root-only)")
        )
  where
    testInitCmd =
        command
            "init"
            ( info
                (pure runTestInit)
                (progDesc "Write <project>.test.dhall next to the project config (needs no pre-existing project config)")
            )
    testRunCmd =
        command
            "run"
            ( info
                (runTestRun <$> caseArg)
                (progDesc ("Run a test suite, or `" ++ allCasesSelector ++ "` for the whole matrix (needs <project>.test.dhall)"))
            )
    caseArg =
        argument
            (eitherReader (either (Left . show) Right . parseCaseSelector . T.pack))
            ( metavar "SUITE"
                <> help ("test suite to run, or `" ++ allCasesSelector ++ "` for the whole matrix")
            )
    -- @test init@ writes the project's test config from defaults (no flags, no
    -- pre-existing project config required): the project's 'psTestInit'
    -- interprets the same defaultless 'InitArgs' the harness uses.
    runTestInit = do
        path <- testDhallPath progName
        let tc = testInit defaultInitArgs
        writeProjectConfigFile testCodec path tc
        putStrLn ("test init: wrote " ++ path)
    -- @test run@ is not context-gated: it does NOT load a sibling project config
    -- (the harness generates it); its guards are the test config's existence
    -- precondition plus the suite's own safety preconditions.
    runTestRun selector = do
        tpath <- testDhallPath progName
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
        project <-
            either
                (die . ("test run: " ++) . T.unpack . Authority.authorityErrorMessage)
                pure
                (Authority.installedProjectFor @projectId @cfg (T.pack progName))
        -- Exclusive run ownership is taken by the protected-store bracket, not
        -- by a bare lock directory: an interrupted run leaves a classifiable
        -- lease the next run's sweep resolves or names for recovery.
        siblingDirectory <- takeDirectory <$> siblingProjectConfigPath (T.pack progName)
        stateRoot <- getCurrentDirectory
        resolved <-
            withCanonicalProjectRoot cfgPath stateRoot $ \canonicalRoot -> do
                let variantFor selectedVariant =
                        ConfigVariant
                            { variantId = variantDraftId draft
                            , variantCaseIds = selectedVariantCaseIds selectedVariant
                            , variantWithConfig = \ownedRoot body ->
                                withOwnedHarnessRoot ownedRoot $ \store ownedProject root -> do
                                    let authority = harnessRootHarnessAuthority root
                                        runName = V.harnessRunName authority
                                    mask $ \restore -> do
                                        withHarnessProjectCodec
                                            @projectId
                                            @cfg
                                            (V.harnessConfigAuthority authority)
                                            ( \harnessCodec -> do
                                                assembled <-
                                                    restore
                                                        ( withAssembledHarnessConfig
                                                            assemblyInputs
                                                            authority
                                                            harnessCodec
                                                            (assemble (HarnessAssembly authority tc draft))
                                                            ( \_wire validated -> do
                                                                case withHarnessLifecycleProfile
                                                                    (harnessRootModeLease root)
                                                                    (harnessRootUnboundLease root) of
                                                                    Left failure ->
                                                                        die (T.unpack (modeErrorMessage failure))
                                                                    Right profile ->
                                                                        case projectPlan canonicalRoot (validatedConfigValue validated) of
                                                                            Left failure ->
                                                                                die ("project plan: " ++ show failure)
                                                                            Right stepPlan ->
                                                                                -- This exact mode/unbound-lease profile gates the
                                                                                -- scope-correct lifecycle plan before any config
                                                                                -- bytes or suite body become live.
                                                                                withProfiledLifecyclePlan profile harnessCodec stepPlan $ \lifecyclePlan -> do
                                                                                    entered <-
                                                                                        withProtectedEntry store $ \session -> do
                                                                                                persisted <-
                                                                                                    persistPlanSnapshot
                                                                                                        session
                                                                                                        ownedProject
                                                                                                        (harnessRootRunId root)
                                                                                                        1
                                                                                                        (projectCodecSpecDigest harnessCodec)
                                                                                                        (lifecyclePlanDigest lifecyclePlan)
                                                                                                bound <- case persisted of
                                                                                                    Left failure -> pure (Left failure)
                                                                                                    Right () ->
                                                                                                        verifyPlanSnapshot session ownedProject (harnessRootRunId root) $ \snapshot ->
                                                                                                            bindRunLease
                                                                                                                session
                                                                                                                ownedProject
                                                                                                                (harnessRootUnboundLease root)
                                                                                                                snapshot
                                                                                                                ( \binding ->
                                                                                                                    pure $ case binding of
                                                                                                                        FreshRunLeaseBinding _ _ -> Right ()
                                                                                                                        ExistingRunLeaseBinding _ _ ->
                                                                                                                            Left
                                                                                                                                ( ModeRecoveryRequired
                                                                                                                                    (runIdText (harnessRootRunId root))
                                                                                                                                )
                                                                                                                )
                                                                                                pure (Right bound)
                                                                                    case entered of
                                                                                        Left failure -> die (T.unpack (protectedErrorMessage failure))
                                                                                        Right (Left failure) -> die (T.unpack (modeErrorMessage failure))
                                                                                        Right (Right ()) -> pure ()
                                                                -- The generated config is acquired under all
                                                                -- four § EE clauses (the test-harness-and-run-ownership phase): a durable
                                                                -- origin record naming the intended payload
                                                                -- precedes the create-if-absent install, and
                                                                -- the created file's own kernel identity is
                                                                -- bound to the receipt.
                                                                ownedPayload <-
                                                                    either die pure
                                                                        =<< acquireOwnedRunConfig
                                                                            ownedRoot
                                                                            ( renderScopedProjectConfigBytes
                                                                                harnessCodec
                                                                                (validatedConfigValue validated)
                                                                            )
                                                                restore
                                                                    ( putStrLn ("test run: generated the run config at " ++ ownedHarnessConfigPath ownedRoot ++ " (variant " ++ T.unpack (variantIdText (variantDraftId draft)) ++ ", run " ++ T.unpack runName ++ ")")
                                                                        >> body
                                                                    )
                                                                    `finally` removeGeneratedConfig ownedRoot ownedPayload
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
                            canonicalRoot
                            siblingDirectory
                            (canonicalProjectRootPath canonicalRoot </> testDataRoot)
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

{- | The per-project @test.dhall@ path: a sibling of the project config (the
@test run@ gate, § Z).
-}
testDhallPath :: String -> IO FilePath
testDhallPath progName = do
    cfgPath <- siblingProjectConfigPath (T.pack progName)
    pure (takeDirectory cfgPath </> (progName ++ ".test.dhall"))

{- | The @check-code@ verb: the fail-fast image-build quality gate. Its body is
supplied by the project spec (or by the explicit bare-core entrypoint).
-}
checkCodeCommand ::
    forall projectId cfg configScope specDigest.
    (ProjectCfg projectId cfg) =>
    ProjectCodec configScope specDigest cfg ->
    String ->
    IO () ->
    Mod CommandFields (IO ())
checkCodeCommand codec progName checkCode =
    command
        "check-code"
        ( info
            (pure (gate @projectId @cfg @configScope codec progName Context.CheckCodeCommand [] checkCode))
            (progDesc "Run the project's fail-fast code-check gate (project-defined body)")
        )

{- | The @context@ command group (§ Z): read-only composition introspection plus
the absorbed read-only config-inspection surfaces (@show@ / @schema@ / @render@ /
@path@). Child-config creation is the @context-init@ chain step inside @project
up@, not a @context@ subcommand; config generation is @project init@.
-}
contextCommand ::
    forall projectId cfg configScope specDigest.
    (ProjectCfg projectId cfg) =>
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
    forall projectId cfg configScope specDigest.
    (ProjectCfg projectId cfg) =>
    ProjectCodec configScope specDigest cfg ->
    String ->
    ( forall rootScope rootId.
      CanonicalProjectRoot rootScope rootId ->
      cfg configScope ->
      Either StepPlanError StepPlan
    ) ->
    (InitArgs -> IO (cfg configScope)) ->
    Mod CommandFields (IO ())
projectCommandGroup codec progName projectPlan initBuilder =
    command
        "project"
        ( info
            (hsubparser (pInit <> pUp <> pDown <> pDestroy))
            (progDesc "Project lifecycle: init the root config, then interpret the chain (up/down/destroy)")
        )
  where
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
            let projectCfg = validatedConfigValue validated :: cfg configScope
            plan <- either (die . ("project plan: " ++) . show) pure (projectPlan root projectCfg)
            if dryRun
                then putStr (renderChain plan)
                else
                    withRootLifecycleAuthority
                        root
                        ctx
                        plan
                        Authority.ProjectUp
                        (applyChain plan root ctx)
    applyChain ::
        forall rootScope rootId.
        StepPlan ->
        CanonicalProjectRoot rootScope rootId ->
        Context.BinaryContext ->
        IO ()
    applyChain plan root ctx = do
        cfg <- hostConfig
        self <- currentSelfRef ("/usr/local/bin/" ++ progName)
        let current = T.unpack (Context.currentFrame ctx)
        -- Guard the chain apply with best-effort teardown: a chain failure — a `Left`
        -- from a non-zero handoff, or a thrown exception — at the ROOT frame runs the
        -- same best-effort teardown as `project destroy`, so a failed `project up`
        -- does not leak the VM + in-VM kind + the global `.wslconfig`. Only the root
        -- frame tears down: a nested frame's failure propagates up to the root (which
        -- alone can reach the VM to delete it and restore `.wslconfig`), and an
        -- uncatchable external kill is handled instead by the idempotent stale-state
        -- reconcile on the next `project up` (phases 5/11).
        -- The interpreter is handed the *lifecycle plan*, not the bare step
        -- ordering: each step's action receives the descriptor that plan mints
        -- for its own node (§ U), so a step can name its operation instead of
        -- reconstructing it.
        --
        -- This opens its own bracket; the root authority gate's has already
        -- closed by now. The digest a step is told is nonetheless the digest the
        -- gate authorized, because both are 'withLifecyclePlan' over the same
        -- codec and the same admitted 'StepPlan', and that derivation is pure.
        outcome <-
            withLifecyclePlan codec plan $ \lifecyclePlan ->
                try (runChainFromFrame cfg self current lifecyclePlan)
        case outcome of
            Right (Right ()) -> pure ()
            Right (Left err)
                | safetyRefusalMarker `isInfixOf` err -> die err
                | otherwise -> failChain plan root cfg ctx err
            Left (exc :: SomeException) ->
                case fromException exc of
                    Just (SafetyRefusal reason) -> die (safetyRefusalMarker ++ " " ++ reason)
                    Nothing -> failChain plan root cfg ctx (show exc)
    {- Run the best-effort `destroy` reverse projection at the root frame, then
    die. It is the *same* projection `project destroy` runs — one representation
    (§ W) — so a failed `project up` cannot leak resources a real destroy would
    have released. Best-effort: the whole unwind must not hinge on one node, and
    the run is failing already, so a failure here is announced and swallowed
    rather than replacing the chain's own cause.
    -}
    failChain ::
        forall rootScope rootId.
        StepPlan ->
        CanonicalProjectRoot rootScope rootId ->
        HostConfig ->
        Context.BinaryContext ->
        String ->
        IO ()
    failChain plan root cfg ctx reason = do
        when (null (Context.parentChain ctx)) $ do
            putStrLn "project up: chain failed — running best-effort teardown (project destroy) so the VM/cluster/.wslconfig are not leaked"
            ignoreChainExc (reverseProjection plan root ctx cfg Teardown.destroyVerb (clusterDelete cfg))
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
            let projectCfg = validatedConfigValue validated :: cfg configScope
            cfg <- hostConfig
            plan <- either (die . ("project plan: " ++) . show) pure (projectPlan root projectCfg)
            withRootLifecycleAuthority root ctx plan Authority.ProjectDown $
                reverseProjection plan root ctx cfg Teardown.downVerb (clusterDown cfg)
    runDestroy =
        withSiblingValidatedProjectConfigRoot codec (T.pack progName) Context.HostOrchestratorCommand [] $ \_wire validated ctx root -> do
            let projectCfg = validatedConfigValue validated :: cfg configScope
            cfg <- hostConfig
            plan <- either (die . ("project plan: " ++) . show) pure (projectPlan root projectCfg)
            withRootLifecycleAuthority root ctx plan Authority.ProjectDestroy $
                reverseProjection plan root ctx cfg Teardown.destroyVerb (clusterDelete cfg)

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
        forall rootScope rootId verb.
        StepPlan ->
        CanonicalProjectRoot rootScope rootId ->
        Context.BinaryContext ->
        HostConfig ->
        Teardown.TeardownVerb verb ->
        (ClusterPlan -> IO ()) ->
        IO ()
    reverseProjection plan root ctx cfg verb clusterEffect =
        withLifecyclePlan codec plan $ \lifecyclePlan -> do
            let projection = Teardown.teardownPlan lifecyclePlan verb
            outcomes <- Teardown.runTeardownProjection projection coreManaged cfg
            reportReverseOutcomes outcomes
      where
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
                    withCurrentDirectory (canonicalProjectRootPath root) (clusterEffect (planForRoot root ctx))
                    pure Step.TeardownReleased
                | otherwise ->
                    pure
                        ( Step.TeardownForeignRetained
                            ( "cluster is owned by a different chain frame; skipping kind cleanup in "
                                ++ T.unpack (Context.currentFrame ctx)
                            )
                        )
            _ -> pure (Step.TeardownForeignRetained "released with the cluster that contains it")

    {- Report every node of the reverse projection, then fail if any attempt
    failed. Independent nodes all get their turn first (§ Y): a failure or a
    refusal skips only its own resource. -}
    reportReverseOutcomes outcomes = do
        mapM_ announce outcomes
        let failures = [T.unpack key ++ ": " ++ detail | (key, Just (Step.TeardownFailed detail)) <- outcomes]
        unless (null failures) $
            die ("project teardown attempted every reverse step but failed:\n" ++ unlines (map ("  - " ++) failures))
      where
        announce (key, outcome) = case outcome of
            Nothing -> pure ()
            Just Step.TeardownReleased -> putStrLn ("project teardown: released " ++ T.unpack key)
            Just (Step.TeardownForeignRetained detail) ->
                putStrLn ("project teardown: retained " ++ T.unpack key ++ " — " ++ detail)
            Just (Step.TeardownRefused detail) ->
                putStrLn ("project teardown: refused " ++ T.unpack key ++ " — " ++ detail)
            Just (Step.TeardownFailed detail) ->
                putStrLn ("project teardown: FAILED " ++ T.unpack key ++ " — " ++ detail)

    {- Run a lifecycle verb behind the independent root gate (the recursive-lifecycle-command phase).

    Before this, @project up|down|destroy@ was authorized by nothing more than
    the decoded context's command-class membership — self-asserted authority of
    exactly the kind § X forbids — and 'Authority.withVerifiedRootInvocation' had
    no production consumer at all, which is why nothing could sign an activation
    manifest for a runtime role.

    The gate runs only at the **root** frame. A nested frame is reached through
    the recursive handoff and must receive its authority from the parent's
    relay, which the recursive-lifecycle-command phase still owes; gating it here would authorize it from
    its own config, which is the thing being removed. So a nested frame passes
    through unchanged and its gating stays explicitly open.

    The store is the project's own @.hostbootstrap/authority@, derived from the
    canonical root rather than the caller's working directory (§ X). The broker
    epoch is fresh per invocation, so the one-use invocation record
    'Authority.authorizeProjectCommand' reserves is fresh per invocation too and
    a re-run is not mistaken for a replay. It fails closed.
    -}
    withRootLifecycleAuthority ::
        forall rootScope rootId verb.
        CanonicalProjectRoot rootScope rootId ->
        Context.BinaryContext ->
        StepPlan ->
        Authority.ProjectVerb verb ->
        IO () ->
        IO ()
    withRootLifecycleAuthority root ctx plan verb body
        | not (null (Context.parentChain ctx)) = body
        | otherwise = do
            project <-
                either
                    (dieAuthority . T.unpack . Authority.authorityErrorMessage)
                    pure
                    (Authority.installedProjectFor @projectId @cfg (T.pack progName))
            store <- openAuthorityStore root
            outcome <-
                withLifecyclePlan codec plan $ \lifecyclePlan ->
                    withAuthorityEntry store $ \session -> do
                        operator <- Authority.verifyOperatorAuthorization session
                        case operator of
                            Left failure -> pure (Left failure)
                            Right authorized ->
                                Authority.withFreshBrokerEpoch session project $ \epoch ->
                                    Authority.withVerifiedRootInvocation
                                        session
                                        project
                                        authorized
                                        epoch
                                        verb
                                        ( \rootAuthority ->
                                            Authority.authorizeProjectCommand
                                                session
                                                project
                                                rootAuthority
                                                lifecyclePlan
                                                Authority.Execute
                                                (Context.currentFrame ctx)
                                                (\_command -> pure (Right ()))
                                        )
            either (dieAuthority . T.unpack . Authority.authorityErrorMessage) pure outcome
            body

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
                (canonicalProjectRootPath root </> ".hostbootstrap" </> "authority" </> progName)
        either (dieAuthority . T.unpack . protectedErrorMessage) pure opened

    withAuthorityEntry ::
        ProtectedStore ->
        ( forall session.
          ProtectedSession session ->
          IO (Either Authority.AuthorityError result)
        ) ->
        IO (Either Authority.AuthorityError result)
    withAuthorityEntry store transaction = do
        outcome <- withProtectedEntry store (fmap Right . transaction)
        pure (either (Left . Authority.AuthorityStoreFailure) id outcome)

    dieAuthority :: String -> IO a
    dieAuthority reason = die ("project: " ++ reason)

-- | Whether the current binary frame owns the chain's cluster lifecycle step.
currentFrameOwnsCluster :: Context.BinaryContext -> StepPlan -> Bool
currentFrameOwnsCluster ctx plan =
    any isDeployKindStep (stepsForFrame current plan)
  where
    current = T.unpack (Context.currentFrame ctx)

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
    forall projectId cfg configScope specDigest.
    (ProjectCfg projectId cfg) =>
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
            (identity, serviceAction) <-
                either
                    (die . ("service run: " ++))
                    pure
                    ( withSelectedServiceRequest
                        (verifiedConfigDigest wire)
                        (inspectLocalContext serviceCtx)
                        projectCfg
                        registry
                        (\selectedIdentity _ _ serviceEffect -> (selectedIdentity, serviceEffect))
                    )
            putStrLn ("service run: selected " ++ serviceIdText identity)
            serviceAction

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
