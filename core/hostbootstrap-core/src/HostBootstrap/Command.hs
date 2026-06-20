{- | The core @optparse-applicative@ command tree.

'coreCommands' is the list of core subcommand entries
('HostBootstrap.CLI.runHostBootstrapCLI' merges it with project commands).
'allReconcilers' is the concrete reconciler set the @ensure@ group dispatches.
-}
module HostBootstrap.Command (
    coreCommands,
    coreCommandNames,
    allReconcilers,
)
where

import Control.Monad (unless, when)
import Data.List (find, intercalate)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import HostBootstrap.Chain (renderChain, runChainFromFrame)
import HostBootstrap.Cluster.Lifecycle (
    ClusterPlan,
    ClusterProfile (Production),
    clusterDelete,
    clusterDown,
    resolvePlan,
 )
import HostBootstrap.Config.Schema (
    DeployConfig (..),
    ProjectConfig (..),
    Resources (..),
    TestConfig (..),
    decodeTestConfigFile,
    defaultTestConfig,
    writeTestConfigFile,
    configRoleNames,
    decodeProjectConfigFile,
    defaultDeployConfig,
    defaultResources,
    parseConfigRole,
    projectConfigFileName,
    projectConfigForRole,
    projectConfigSchemaText,
    renderProjectConfigSummary,
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
import HostBootstrap.Ensure (Reconciler, ensureCommandWith)
import qualified HostBootstrap.Ensure.Colima as Colima
import qualified HostBootstrap.Ensure.Cuda as Cuda
import qualified HostBootstrap.Ensure.Docker as Docker
import qualified HostBootstrap.Ensure.Ghc as Ghc
import qualified HostBootstrap.Ensure.Homebrew as Homebrew
import qualified HostBootstrap.Ensure.Incus as Incus
import qualified HostBootstrap.Ensure.Lima as Lima
import qualified HostBootstrap.Ensure.Tart as Tart
import HostBootstrap.Harness (TestSuite, allCasesSelector, allPassed, reportCard, runSuiteSelection, testSuiteCaseIds)
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.Lift (LiftContext, currentSelfRef)
import HostBootstrap.Service (ServiceRegistry, lookupServiceHandler, serviceRun, serviceVariantNames)
import HostBootstrap.Step (Step, StepFrame)
import HostBootstrap.Substrate (detect)
import Options.Applicative
import System.Directory (doesFileExist, getCurrentDirectory, withCurrentDirectory)
import System.Environment (getExecutablePath)
import System.Exit (die)
import System.FilePath (takeDirectory, (</>))

{- | The concrete @ensure@ reconcilers (the six host-tool reconcilers plus the
cross-substrate host-provider @ensure incus@).
-}
allReconcilers :: [Reconciler]
allReconcilers =
    [ Docker.reconciler
    , Colima.reconciler
    , Cuda.reconciler
    , Homebrew.reconciler
    , Ghc.reconciler
    , Tart.reconciler
    , Lima.reconciler
    , Incus.reconciler
    ]

{- | The top-level core command names. Project binaries append project commands
under distinct names; 'HostBootstrap.CLI' rejects a project command that would
shadow one of these.
-}
coreCommandNames :: [String]
coreCommandNames = ["ensure", "context", "project", "test", "service", "check-code"]

{- | The core subcommands every @hostbootstrap@-derived binary exposes. The
project's 'TestSuite' is threaded into the inherited @test@ verb so a project's
cases run under @test@ (not a per-noun subcommand).
-}
coreCommands ::
    String ->
    [ConfigArtifact] ->
    TestSuite ->
    IO () ->
    ServiceRegistry ->
    (ProjectConfig -> [Step]) ->
    (ProjectConfig -> StepFrame -> LiftContext) ->
    (ProjectConfig -> Bool -> IO ()) ->
    [Mod CommandFields (IO ())]
coreCommands progName projectArtifacts suite checkCode services chain frameCtx teardown =
    [ ensureCommandWith (gate progName Context.EnsureCommand []) allReconcilers
    , contextCommand progName projectArtifacts
    , projectCommandGroup progName chain frameCtx teardown
    , testCommand progName suite
    , serviceCommandGroup progName services
    , checkCodeCommand progName checkCode
    ]

gate :: String -> Context.CommandClass -> [Context.Capability] -> IO () -> IO ()
gate progName commandClass caps body =
    withSiblingProjectConfigContext (T.pack progName) commandClass caps (\_ _ -> body)

{- | The @test@ verb: select over the project's case matrix and print the report
card. @test all@ runs the whole matrix; @test \<case\>@ runs the single case
with that id (an unknown id fails fast, listing the valid ids). The bare binary
reaches this through the explicit bare entrypoint; a project supplies its
non-empty matrix and seams as the 'TestSuite' threaded through
'HostBootstrap.CLI.runHostBootstrapCLI'.
-}
testCommand :: String -> TestSuite -> Mod CommandFields (IO ())
testCommand progName suite =
    command
        "test"
        ( info
            (hsubparser (testInitCmd <> testRunCmd))
            (progDesc "Test surface: `init` writes test.dhall; `run` runs a suite against the live stack (root-only)")
        )
  where
    testInitCmd =
        command
            "init"
            ( info
                (pure runTestInit)
                (progDesc "Write test.dhall next to the project config (requires an existing project config)")
            )
    testRunCmd =
        command
            "run"
            ( info
                (runTestRun <$> caseArg)
                (progDesc ("Run a test suite, or `" ++ allCasesSelector ++ "` for the whole matrix (needs test.dhall)"))
            )
    caseArg =
        strArgument
            ( metavar "SUITE"
                <> help ("test suite to run, or `" ++ allCasesSelector ++ "` for the whole matrix")
            )
    -- The test surface gates as 'TestWorkflowCommand', the class permitted in
    -- every frame that hosts the standardized harness (the orchestration frames
    -- and the TestHarness frame), so @test run@ runs wherever the kind tooling
    -- lives — directly on a host that has it, or lifted into the VM/container.
    -- @test init@ needs the project config's resources to seed the test-config
    -- override, so it gates with the config in hand (not the discarding 'gate').
    runTestInit = withSiblingProjectConfigContext (T.pack progName) Context.TestWorkflowCommand [] $ \cfg _ctx -> do
        path <- testDhallPath progName
        let tc = defaultTestConfig (map T.pack (testSuiteCaseIds suite ++ [allCasesSelector])) (resources cfg)
        writeTestConfigFile path tc
        putStrLn ("test init: wrote " ++ path)
    runTestRun selector = gate progName Context.TestWorkflowCommand [] $ do
        path <- testDhallPath progName
        exists <- doesFileExist path
        unless exists (die ("test run: missing " ++ path ++ "; run `" ++ progName ++ " test init` first"))
        -- Read the test-config overrides (§ Z): the resources the test stack runs
        -- at, projected from test.dhall. A project's bring-up honours them; the demo
        -- runs at its declared budget (its test resources equal its config's).
        tc <- decodeTestConfigFile path
        let r = testResources tc
        putStrLn
            ( "test run: test-config resources cpu="
                ++ show (cpu r)
                ++ " memory="
                ++ T.unpack (memory r)
                ++ " storage="
                ++ T.unpack (storage r)
            )
        outcome <- runSuiteSelection suite selector
        case outcome of
            Left err -> die err
            Right report -> do
                putStr (reportCard report)
                unless (allPassed report) (die "test: one or more cases failed")

-- | The per-project @test.dhall@ path: a sibling of the project config (the
-- @test run@ gate, § Z).
testDhallPath :: String -> IO FilePath
testDhallPath progName = do
    cfgPath <- siblingProjectConfigPath (T.pack progName)
    pure (takeDirectory cfgPath </> (progName ++ ".test.dhall"))


{- | The @check-code@ verb: the fail-fast image-build quality gate. Its body is
supplied by the project spec (or by the explicit bare-core entrypoint).
-}
checkCodeCommand :: String -> IO () -> Mod CommandFields (IO ())
checkCodeCommand progName checkCode =
    command
        "check-code"
        ( info
            (pure (gate progName Context.CheckCodeCommand [] checkCode))
            (progDesc "Run the project's fail-fast code-check gate (project-defined body)")
        )

{- | The @context@ command group (§ Z): read-only composition introspection plus
the absorbed read-only config-inspection surfaces (@show@ / @schema@ / @render@ /
@path@). Child-config creation is the @context-init@ chain step inside @project
up@, not a @context@ subcommand; config generation is @project init@.
-}
contextCommand :: String -> [ConfigArtifact] -> Mod CommandFields (IO ())
contextCommand progName projectArtifacts =
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
                (progDesc "Decode a <project>.dhall and print its fields")
            )
    showAction path = do
        cfg <- decodeProjectConfigFile path
        putStr (renderProjectConfigSummary cfg)

    schemaCmd =
        command
            "schema"
            ( info
                (pure schemaAction)
                (progDesc "Print the Dhall schema the binary's decoders accept (the in-scope artifact union)")
            )
    schemaAction =
        putStrLn $
            T.unpack $
                schemaUnion artifacts
                    <> T.pack "\n\n-- projectConfig\n"
                    <> projectConfigSchemaText

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
        ProjectConfig _ _ ctx _ <- decodeProjectConfigFile path
        putStr (Context.renderComposition ctx)

{- | The @init@ parser shared by @project init@ (§ Y) and @service init@ (§ AA):
write a project-local @<project>.dhall@ without requiring an existing config (a
bootstrap entrypoint). @defaultRole@ selects the role the generated config
declares when @--role@ is not given (@host-orchestrator@ for @project init@,
@cluster-service@ for @service init@). Python triggers @project init@
idempotently after the host-native build (§ M).
-}
initParserInfo :: String -> String -> ParserInfo (IO ())
initParserInfo progName defaultRole =
    info
        ( initAction
            <$> optional outputOpt
            <*> roleOpt
            <*> optional initSourceRootOpt
            <*> dockerfileOpt
            <*> optional initCpuOpt
            <*> memoryOpt
            <*> storageOpt
            <*> optional haReplicasOpt
            <*> switch (long "force" <> help "overwrite OUTPUT when it already exists")
            <*> switch (long "if-missing" <> help "no-op when OUTPUT already exists (idempotent ensure)")
            <*> many alsoRoleOpt
        )
        (progDesc "Write a default project-local <project>.dhall without requiring an existing config")
  where
    initAction moutput roleName mroot cfgDockerfile mcpu cfgMemory cfgStorage mha force ifMissing alsoRoles = do
        role <- either die pure (parseConfigRole roleName)
        -- A config may declare more than one role (§ X): the primary --role plus
        -- any --also-role grants (e.g. a project authority that is also a service
        -- authority). Each grant unions the role's command classes + capabilities.
        extraRoles <- mapM (either die pure . parseConfigRole) alsoRoles
        root <- maybe getCurrentDirectory pure mroot
        output <- maybe defaultProjectConfigPath pure moutput
        let cfgResources =
                Resources
                    { cpu = fromMaybe (cpu defaultResources) mcpu
                    , memory = T.pack cfgMemory
                    , storage = T.pack cfgStorage
                    }
            cfgDeploy = DeployConfig{haReplicas = fromMaybe (haReplicas defaultDeployConfig) mha}
            baseCfg =
                projectConfigForRole
                    (T.pack progName)
                    (T.pack progName)
                    (T.pack root)
                    (T.pack cfgDockerfile)
                    cfgResources
                    cfgDeploy
                    role
            cfg = baseCfg{context = foldr Context.addRole (context baseCfg) extraRoles}
        exists <- doesFileExist output
        if exists && ifMissing && not force
            then putStrLn ("config init: " ++ output ++ " already present")
            else do
                when (exists && not force) $
                    die ("config init: " ++ output ++ " already exists (pass --force to overwrite)")
                writeProjectConfigFile output cfg
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
                <> value "docker/Dockerfile"
                <> showDefault
                <> help "project Dockerfile path recorded in the generated config"
            )
    initSourceRootOpt =
        strOption
            ( long "source-root"
                <> metavar "DIR"
                <> help "source root recorded in the generated context; defaults to the current directory"
            )
    initCpuOpt =
        option auto (long "cpu" <> metavar "N" <> help "CPU resource budget")
    memoryOpt =
        strOption
            ( long "memory"
                <> metavar "TEXT"
                <> value (T.unpack (memory defaultResources))
                <> showDefault
                <> help "memory resource budget"
            )
    storageOpt =
        strOption
            ( long "storage"
                <> metavar "TEXT"
                <> value (T.unpack (storage defaultResources))
                <> showDefault
                <> help "storage resource budget"
            )
    haReplicasOpt =
        option auto (long "ha-replicas" <> metavar "N" <> help "HA replica count recorded in deploy settings")

{- | The @project@ lifecycle command (§ Y): @init@ writes the root config, then
the recursive interpreter brings the chain @up@ / @down@ / @destroy@. @project up
--dry-run@ renders the pure @chain rootCfg@ plan (the single representation, § W);
@project up@ interprets it recursively from the current frame; @project down@
stops services/clusters/VMs without deleting them; @project destroy@ deletes
everything spun up while preserving host @.data@.
-}
projectCommandGroup ::
    String ->
    (ProjectConfig -> [Step]) ->
    (ProjectConfig -> StepFrame -> LiftContext) ->
    (ProjectConfig -> Bool -> IO ()) ->
    Mod CommandFields (IO ())
projectCommandGroup progName chain frameCtx teardown =
    command
        "project"
        ( info
            (hsubparser (pInit <> pUp <> pDown <> pDestroy))
            (progDesc "Project lifecycle: init the root config, then interpret the chain (up/down/destroy)")
        )
  where
    pInit = command "init" (initParserInfo progName "host-orchestrator")
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
            (info (pure runDown) (progDesc "Stop services/clusters/VMs without deleting them; preserve host .data"))
    pDestroy =
        command
            "destroy"
            (info (pure runDestroy) (progDesc "Stop then delete everything spun up; preserve host .data"))

    -- @project up@ is the recursive interpreter that runs in EVERY orchestration
    -- frame (host → VM → container), so it gates as 'ClusterLifecycleCommand',
    -- which is permitted in all three orchestration kinds (HostOrchestrator /
    -- VMOrchestrator / VMProjectContainer) and rejected in the
    -- ClusterService / Daemon / ImageBuildContainer leaves, where a recursive
    -- @project up@ must not run (§ X).
    runUp dryRun =
        withSiblingProjectConfigContext (T.pack progName) Context.ClusterLifecycleCommand [] $ \rootCfg ctx ->
            if dryRun
                then putStr (renderChain (chain rootCfg))
                else applyChain rootCfg ctx
    applyChain rootCfg ctx = do
        cfg <- hostConfig
        self <- currentSelfRef ("/usr/local/bin/" ++ progName)
        let current = T.unpack (Context.currentFrame ctx)
        result <- runChainFromFrame cfg self (frameCtx rootCfg) current (chain rootCfg)
        either die pure result

    -- Teardown runs the cluster-lifecycle reconciler (clusterDown / clusterDelete,
    -- which never remove host @.data@, § O), then the project's chain-frame
    -- 'teardown' stops (down) or deletes (destroy) the provisioned frames. For a
    -- project whose cluster lives inside a provider VM (the demo), the VM is the
    -- wall: stopping or deleting the VM takes the in-VM cluster down with it, so
    -- the host-side cluster reconciler is a no-op there and the VM teardown is the
    -- effective one.
    runDown =
        withSiblingProjectConfigContext (T.pack progName) Context.HostOrchestratorCommand [] $ \rootCfg ctx -> do
            cfg <- hostConfig
            withCurrentDirectory (T.unpack (Context.sourceRoot ctx)) (clusterDown cfg (planForContext ctx))
            teardown rootCfg False
    runDestroy =
        withSiblingProjectConfigContext (T.pack progName) Context.HostOrchestratorCommand [] $ \rootCfg ctx -> do
            cfg <- hostConfig
            withCurrentDirectory (T.unpack (Context.sourceRoot ctx)) (clusterDelete cfg (planForContext ctx))
            teardown rootCfg True

{- | The @service@ lifecycle command (§ AA): the third DSL-driven core command,
for a project's long-running roles (the @HostDaemon@/service run-model). @init@
writes a service-configured @<project>.dhall@; @schema@ prints the service config
schema (reflected from the decoder, § Q) and the registered variants; @run
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
serviceCommandGroup :: String -> ServiceRegistry -> Mod CommandFields (IO ())
serviceCommandGroup progName registry =
    command
        "service"
        ( info
            (hsubparser (sInit <> sSchema <> sRun))
            (progDesc "Service lifecycle: init the service config, print the schema, run a long-running role")
        )
  where
    sInit = command "init" (initParserInfo progName "cluster-service")
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
        putStrLn "-- projectConfig"
        putStrLn (T.unpack projectConfigSchemaText)
    runServiceRun variant =
        gate progName Context.ServiceCommand [] $
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

