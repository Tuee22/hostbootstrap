{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The core @optparse-applicative@ command tree.

'coreCommands' is the list of fixed core subcommand entries every derived
binary exposes. 'allReconcilers' is the concrete reconciler library projects
compose into @ensure-*@ chain steps.

The command tree is **generic over a project's config type** ('ProjectCfg'): it
never names a concrete config record. It decodes/encodes the sibling config via
@FromDhall@/@ToDhall@, reaches the embedded context through 'cfgContext', and
obtains a concrete config solely from the project-owned builders ('psInit' /
'psTestInit' / 'psTestConfig') threaded in from the spec — the **only** place
config defaults live.
-}
module HostBootstrap.Command (
    coreCommands,
    coreCommandNames,
    allReconcilers,
)
where

import Control.Exception (SomeException)
import Control.Exception.Safe (finally, try)
import Control.Monad (unless, when)
import Data.List (find, intercalate)
import qualified Data.Text as T
import qualified Dhall
import HostBootstrap.Chain (renderChain, runChainFromFrame)
import HostBootstrap.Cluster.Lifecycle (
    ClusterPlan,
    ClusterProfile (Production),
    clusterDelete,
    clusterDown,
    resolvePlan,
 )
import HostBootstrap.Config.Class (InitArgs (..), ProjectCfg (..), projectCfgSchemaText)
import HostBootstrap.Config.Schema (
    configRoleNames,
    parseConfigRole,
    projectConfigFileName,
    siblingProjectConfigPath,
    withSiblingProjectConfigContext,
    writeProjectConfigFile,
 )
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (
    ConfigArtifact (..),
    coreArtifacts,
    schemaUnion,
 )
import HostBootstrap.Ensure (Reconciler)
import qualified HostBootstrap.Ensure.Colima as Colima
import qualified HostBootstrap.Ensure.Cuda as Cuda
import qualified HostBootstrap.Ensure.CudaWin as CudaWin
import qualified HostBootstrap.Ensure.Docker as Docker
import qualified HostBootstrap.Ensure.Ghc as Ghc
import qualified HostBootstrap.Ensure.Homebrew as Homebrew
import qualified HostBootstrap.Ensure.Incus as Incus
import qualified HostBootstrap.Ensure.Lima as Lima
import qualified HostBootstrap.Ensure.Wsl2 as Wsl2
import HostBootstrap.Harness (ConfigVariant (..), TestSuite, allCasesSelector, allPassed, reportCard, runSuiteSelection)
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.Lift (LiftContext, currentSelfRef)
import HostBootstrap.Service (ServiceRegistry, lookupServiceHandler, serviceRun, serviceVariantNames)
import HostBootstrap.Step (Step, StepFrame)
import HostBootstrap.Substrate (detect)
import Numeric.Natural (Natural)
import Options.Applicative
import System.Directory (doesFileExist, removeFile, withCurrentDirectory)
import System.Environment (getExecutablePath)
import System.Exit (die)
import System.FilePath (takeDirectory, (</>))

{- | The concrete @ensure@ reconciler library — the host-configuration
primitives, including the cross-substrate host-provider @incus@ reconciler.
-}
allReconcilers :: [Reconciler]
allReconcilers =
    [ Docker.reconciler
    , Colima.reconciler
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
cases run under @test@ (not a per-noun subcommand). The project's config builders
('psInit' / 'psTestInit' / 'psTestConfig') are threaded in too: @init@ writes via
'psInit', @test init@ writes via 'psTestInit', and @test run@ generates the run
config via 'psTestConfig'.
-}
coreCommands ::
    forall cfg tcfg.
    (ProjectCfg cfg, Dhall.FromDhall tcfg, Dhall.ToDhall tcfg) =>
    String ->
    [ConfigArtifact] ->
    TestSuite ->
    IO () ->
    ServiceRegistry ->
    (cfg -> [Step]) ->
    (cfg -> StepFrame -> LiftContext) ->
    (cfg -> Bool -> IO ()) ->
    (InitArgs -> cfg) ->
    (InitArgs -> tcfg) ->
    (tcfg -> IO [(T.Text, cfg)]) ->
    [Mod CommandFields (IO ())]
coreCommands progName projectArtifacts suite checkCode services chain frameCtx teardown initBuilder testInit testConfig =
    [ contextCommand @cfg progName projectArtifacts initBuilder
    , projectCommandGroup progName chain frameCtx teardown initBuilder
    , testCommand @cfg @tcfg progName suite initBuilder testInit testConfig
    , serviceCommandGroup progName services initBuilder
    , checkCodeCommand @cfg progName checkCode
    ]

gate :: forall cfg. (ProjectCfg cfg) => String -> Context.CommandClass -> [Context.Capability] -> IO () -> IO ()
gate progName commandClass caps body =
    withSiblingProjectConfigContext (T.pack progName) commandClass caps (\(_ :: cfg) _ -> body)

{- | The @test@ verb: a two-subcommand surface (@init@ and @run@). @test run@
selects over the project's case matrix and prints the report card — @test run
all@ runs the whole matrix; @test run \<case\>@ runs the single case with that id
(an unknown id fails fast, listing the valid ids). The bare binary reaches this
through the explicit bare entrypoint; a project supplies its non-empty matrix and
seams as the 'TestSuite' threaded through 'HostBootstrap.CLI.runHostBootstrapCLI'.

@test init@ writes the project's test config via 'psTestInit' (it needs **no**
pre-existing project config — a bootstrap entrypoint). @test run@ reads that test
config, builds the run's project config via 'psTestConfig', writes it as the
sibling @<project>.dhall@, drives the suite against the live stack, then deletes
the **generated** config (keeping the test config).
-}
testCommand ::
    forall cfg tcfg.
    (ProjectCfg cfg, Dhall.FromDhall tcfg, Dhall.ToDhall tcfg) =>
    String ->
    TestSuite ->
    (InitArgs -> cfg) ->
    (InitArgs -> tcfg) ->
    (tcfg -> IO [(T.Text, cfg)]) ->
    Mod CommandFields (IO ())
testCommand progName suite _initBuilder testInit testConfig =
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
        strArgument
            ( metavar "SUITE"
                <> help ("test suite to run, or `" ++ allCasesSelector ++ "` for the whole matrix")
            )
    -- @test init@ writes the project's test config from defaults (no flags, no
    -- pre-existing project config required): the project's 'psTestInit'
    -- interprets the same defaultless 'InitArgs' the harness uses.
    runTestInit = do
        path <- testDhallPath progName
        let tc = testInit defaultInitArgs
        writeProjectConfigFile path tc
        putStrLn ("test init: wrote " ++ path)
    -- @test run@ is not context-gated: it does NOT load a sibling project config
    -- (the harness generates it); its guards are the test config's existence
    -- precondition plus the suite's own safety preconditions.
    runTestRun selector = do
        tpath <- testDhallPath progName
        exists <- doesFileExist tpath
        unless exists (die ("test run: missing " ++ tpath ++ "; run `" ++ progName ++ " test init` first"))
        tc <- Dhall.inputFile Dhall.auto tpath :: IO tcfg
        cfgPath <- siblingProjectConfigPath (T.pack progName)
        cfgExists <- doesFileExist cfgPath
        when cfgExists $
            die ("test run: a production config already exists at " ++ cfgPath ++ "; refusing to overwrite it")
        -- The run config is generated from the test config: a NON-EMPTY list of
        -- labeled variants. Each variant writes its own sibling <project>.dhall
        -- before bring-up and deletes it after teardown, so the harness drives a
        -- full teardown + spin-up between variants.
        labeledCfgs <- testConfig tc
        when (null labeledCfgs) (die "test run: the project generated no test-config variants")
        let variantFor (label, cfg) =
                ConfigVariant
                    { variantLabel = label
                    , variantWithConfig = \body -> do
                        writeProjectConfigFile cfgPath cfg
                        putStrLn ("test run: generated the run config at " ++ cfgPath ++ " (variant " ++ T.unpack label ++ ")")
                        body `finally` removeGeneratedConfig cfgPath
                    }
        outcome <- runSuiteSelection suite (map variantFor labeledCfgs) selector
        case outcome of
            Left err -> die err
            Right report -> do
                putStr (reportCard report)
                unless (allPassed report) (die "test: one or more cases failed")
    removeGeneratedConfig cfgPath = do
        present <- doesFileExist cfgPath
        when present (removeFile cfgPath)

-- | The defaultless @init@ flag bundle the @test init@ / harness path uses: no
-- output/source-root/role overrides, so the project's builder supplies all
-- defaults.
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

-- | The per-project @test.dhall@ path: a sibling of the project config (the
-- @test run@ gate, § Z).
testDhallPath :: String -> IO FilePath
testDhallPath progName = do
    cfgPath <- siblingProjectConfigPath (T.pack progName)
    pure (takeDirectory cfgPath </> (progName ++ ".test.dhall"))

{- | The @check-code@ verb: the fail-fast image-build quality gate. Its body is
supplied by the project spec (or by the explicit bare-core entrypoint).
-}
checkCodeCommand :: forall cfg. (ProjectCfg cfg) => String -> IO () -> Mod CommandFields (IO ())
checkCodeCommand progName checkCode =
    command
        "check-code"
        ( info
            (pure (gate @cfg progName Context.CheckCodeCommand [] checkCode))
            (progDesc "Run the project's fail-fast code-check gate (project-defined body)")
        )

{- | The @context@ command group (§ Z): read-only composition introspection plus
the absorbed read-only config-inspection surfaces (@show@ / @schema@ / @render@ /
@path@). Child-config creation is the @context-init@ chain step inside @project
up@, not a @context@ subcommand; config generation is @project init@.
-}
contextCommand ::
    forall cfg.
    (ProjectCfg cfg) =>
    String ->
    [ConfigArtifact] ->
    (InitArgs -> cfg) ->
    Mod CommandFields (IO ())
contextCommand progName projectArtifacts _initBuilder =
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
        decoded <- try (Dhall.inputFile Dhall.auto path :: IO cfg)
        case decoded of
            Left (e :: SomeException) ->
                die ("context: failed to decode " ++ path ++ ": " ++ takeWhile (/= '\n') (show e))
            Right cfg -> pure cfg

{- | The @init@ parser shared by @project init@ (§ Y) and @service init@ (§ AA):
write a project-local @<project>.dhall@ without requiring an existing config (a
bootstrap entrypoint). @defaultRole@ selects the role the generated config
declares when @--role@ is not given (@host-orchestrator@ for @project init@,
@cluster-service@ for @service init@). The flags carry **no** core default values
(the project's 'psInit' supplies every omitted default), so the parser yields a
defaultless 'InitArgs' which 'psInit' interprets. Python does not trigger this
surface; it builds the host-native binary and execs it (§ M).
-}
initParserInfo ::
    forall cfg.
    (ProjectCfg cfg) =>
    String ->
    String ->
    String ->
    (InitArgs -> cfg) ->
    ParserInfo (IO ())
initParserInfo progName commandLabel defaultRole initBuilder =
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
            cfg = initBuilder args
        outPath <- maybe defaultProjectConfigPath pure moutput
        exists <- doesFileExist outPath
        if exists && ifMissingFlag && not forceFlag
            then putStrLn (commandLabel ++ ": " ++ outPath ++ " already present")
            else do
                when (exists && not forceFlag) $
                    die (commandLabel ++ ": " ++ outPath ++ " already exists (pass --force to overwrite)")
                writeProjectConfigFile outPath cfg
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
stops service/VM frames and tears down kind clusters while preserving durable
host @.data@; @project destroy@ deletes everything spun up while preserving host
@.data@.
-}
projectCommandGroup ::
    forall cfg.
    (ProjectCfg cfg) =>
    String ->
    (cfg -> [Step]) ->
    (cfg -> StepFrame -> LiftContext) ->
    (cfg -> Bool -> IO ()) ->
    (InitArgs -> cfg) ->
    Mod CommandFields (IO ())
projectCommandGroup progName chain frameCtx teardown initBuilder =
    command
        "project"
        ( info
            (hsubparser (pInit <> pUp <> pDown <> pDestroy))
            (progDesc "Project lifecycle: init the root config, then interpret the chain (up/down/destroy)")
        )
  where
    pInit = command "init" (initParserInfo progName "project init" "host-orchestrator" initBuilder)
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
            (info (pure runDown) (progDesc "Stop service/VM frames and tear down kind clusters; preserve host .data"))
    pDestroy =
        command
            "destroy"
            (info (pure runDestroy) (progDesc "Stop then delete everything spun up; preserve host .data"))

    -- @project up@ is the recursive interpreter that runs in EVERY orchestration
    -- frame (host → VM → container), so it gates as 'ClusterLifecycleCommand',
    -- which is permitted in the three orchestration kinds (HostOrchestrator /
    -- VMOrchestrator / VMProjectContainer) plus the TestHarness kind, and
    -- rejected in the ClusterService / Daemon / OneShotJob / ImageBuildContainer
    -- leaves, where a recursive @project up@ must not run (§ X).
    runUp dryRun =
        withSiblingProjectConfigContext (T.pack progName) Context.ClusterLifecycleCommand [] $ \(projectCfg :: cfg) ctx ->
            if dryRun
                then putStr (renderChain (chain projectCfg))
                else applyChain projectCfg ctx
    applyChain projectCfg ctx = do
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
        outcome <- try (runChainFromFrame cfg self (frameCtx projectCfg) current (chain projectCfg))
        case outcome of
            Right (Right ()) -> pure ()
            Right (Left err) -> failChain cfg projectCfg ctx err
            Left (exc :: SomeException) -> failChain cfg projectCfg ctx (show exc)
    -- Run the best-effort `project destroy` teardown at the root frame, then die.
    failChain cfg projectCfg ctx reason = do
        when (null (Context.parentChain ctx)) $ do
            putStrLn "project up: chain failed — running best-effort teardown (project destroy) so the VM/cluster/.wslconfig are not leaked"
            ignoreChainExc (withCurrentDirectory (T.unpack (Context.sourceRoot ctx)) (clusterDelete cfg (planForContext ctx)))
            ignoreChainExc (teardown projectCfg True)
        die reason
    -- Swallow a teardown step's exception (best-effort): the whole teardown must not
    -- hinge on one step succeeding.
    ignoreChainExc act = do
        r <- try act
        case (r :: Either SomeException ()) of
            Right () -> pure ()
            Left e -> putStrLn ("  (teardown step skipped: " ++ show e ++ ")")

    -- Teardown runs the cluster-lifecycle reconciler (clusterDown / clusterDelete,
    -- which never remove host @.data@, § O), then the project's chain-frame
    -- 'teardown' stops (down) or deletes (destroy) the provisioned frames. For a
    -- project whose cluster lives inside a provider VM (the demo), the VM is the
    -- wall: stopping or deleting the VM takes the in-VM cluster down with it, so
    -- the host-side cluster reconciler is a no-op there and the VM teardown is the
    -- effective one.
    runDown =
        withSiblingProjectConfigContext (T.pack progName) Context.HostOrchestratorCommand [] $ \(projectCfg :: cfg) ctx -> do
            cfg <- hostConfig
            withCurrentDirectory (T.unpack (Context.sourceRoot ctx)) (clusterDown cfg (planForContext ctx))
            teardown projectCfg False
    runDestroy =
        withSiblingProjectConfigContext (T.pack progName) Context.HostOrchestratorCommand [] $ \(projectCfg :: cfg) ctx -> do
            cfg <- hostConfig
            withCurrentDirectory (T.unpack (Context.sourceRoot ctx)) (clusterDelete cfg (planForContext ctx))
            teardown projectCfg True

{- | The @service@ lifecycle command (§ AA): the third DSL-driven core command,
for a project's long-running roles (the @HostDaemon@/service run-model). @init@
writes a service-configured @<project>.dhall@; @schema@ prints the service config
schema (the in-scope artifact union, § Q) and the registered variants; @run
\<variant\>@ runs the selected role. There is **no @service down@** — a service's
lifetime is owned by its Kubernetes controller and torn down by @project
destroy@ (§ Y).

@service run@ is a **leaf-frame runtime command, never an orchestrator**: the
context gate refuses it unless the effective @<project>.dhall@ declares a service
role (the 'Context.ServiceCommand' class, which only the @cluster-service@ /
@daemon@ leaf contexts allow), so a host/VM/container orchestrator config — or a
missing config — fails fast. It then dispatches on the variant; an unknown
variant or an empty registry fails fast.
-}
serviceCommandGroup ::
    forall cfg.
    (ProjectCfg cfg) =>
    String ->
    ServiceRegistry ->
    (InitArgs -> cfg) ->
    Mod CommandFields (IO ())
serviceCommandGroup progName registry initBuilder =
    command
        "service"
        ( info
            (hsubparser (sInit <> sSchema <> sRun))
            (progDesc "Service lifecycle: init the service config, print the schema, run a long-running role")
        )
  where
    sInit = command "init" (initParserInfo progName "service init" "cluster-service" initBuilder)
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
                (runServiceRun <$> variantArg)
                (progDesc "Run the named service variant (leaf-frame; needs a service-role config)")
            )
    variantArg =
        strArgument
            ( metavar "VARIANT"
                <> help "service variant to run (one of the project's registered variants)"
            )
    runSchema = do
        putStrLn "service variants:"
        case serviceVariantNames registry of
            [] -> putStrLn "  (none registered)"
            names -> mapM_ (\n -> putStrLn ("  " ++ n)) names
        putStrLn ""
        putStrLn "-- <project>.dhall (service-config schema, reflected from the decoder)"
        putStrLn (T.unpack (projectCfgSchemaText @cfg))
    runServiceRun variant =
        gate @cfg progName Context.ServiceCommand [] $
            case lookupServiceHandler variant registry of
                Just handler -> serviceRun handler
                Nothing ->
                    die
                        ( "service run: unknown service variant "
                            ++ show variant
                            ++ "; "
                            ++ case serviceVariantNames registry of
                                [] -> "this binary registers no service variants"
                                names -> "registered: " ++ intercalate ", " names
                        )

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

-- | The production cluster plan, rooted at the active context's source root.
planForContext :: Context.BinaryContext -> ClusterPlan
planForContext ctx =
    resolvePlan (T.unpack (Context.project ctx)) (T.unpack (Context.sourceRoot ctx)) Production
