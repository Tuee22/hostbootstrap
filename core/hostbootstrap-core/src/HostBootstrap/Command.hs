-- | The core @optparse-applicative@ command tree.
--
-- 'coreCommands' is the list of core subcommand entries
-- ('HostBootstrap.CLI.runHostBootstrapCLI' merges it with project commands).
-- 'allReconcilers' is the concrete reconciler set the @ensure@ group dispatches.
module HostBootstrap.Command
  ( coreCommands,
    allReconcilers,
  )
where

import HostBootstrap.Cluster.Lifecycle
  ( ClusterPlan,
    ClusterProfile (Production),
    clusterDelete,
    clusterDown,
    clusterStatus,
    clusterUp,
    resolvePlan,
  )
import HostBootstrap.Config.Schema
  ( Resources (..),
    decodeStaticBaseFile,
    renderStaticBase,
  )
import Control.Monad (unless)
import qualified Data.Text as T
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen
  ( ConfigArtifact (..),
    coreArtifacts,
    schemaUnion,
  )
import HostBootstrap.Harness (TestSuite, allCasesSelector, reportCard, runSuiteSelection)
import HostBootstrap.Ensure (Reconciler, ensureCommandWith)
import qualified HostBootstrap.Ensure.Colima as Colima
import qualified HostBootstrap.Ensure.Cuda as Cuda
import qualified HostBootstrap.Ensure.Docker as Docker
import qualified HostBootstrap.Ensure.Ghc as Ghc
import qualified HostBootstrap.Ensure.Homebrew as Homebrew
import qualified HostBootstrap.Ensure.Incus as Incus
import qualified HostBootstrap.Ensure.Tart as Tart
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.Substrate (detect)
import Options.Applicative
import System.Directory (getCurrentDirectory, withCurrentDirectory)
import System.Exit (die)

-- | The concrete @ensure@ reconcilers (the six host-tool reconcilers plus the
-- cross-substrate host-provider @ensure incus@).
allReconcilers :: [Reconciler]
allReconcilers =
  [ Docker.reconciler,
    Colima.reconciler,
    Cuda.reconciler,
    Homebrew.reconciler,
    Ghc.reconciler,
    Tart.reconciler,
    Incus.reconciler
  ]

-- | The core subcommands every @hostbootstrap@-derived binary exposes. The
-- project's 'TestSuite' is threaded into the inherited @test@ verb so a project's
-- cases run under @test@ (not a per-noun subcommand).
coreCommands :: String -> TestSuite -> [Mod CommandFields (IO ())]
coreCommands progName suite =
  [ ensureCommandWith (gate progName Context.EnsureCommand []) allReconcilers,
    configCommand progName,
    contextCommand progName,
    clusterCommand progName,
    testCommand progName suite,
    checkCodeCommand progName
  ]

gate :: String -> Context.CommandClass -> [Context.Capability] -> IO () -> IO ()
gate progName commandClass caps body =
  Context.withSiblingContext (T.pack progName) commandClass caps (const body)

-- | The @test@ verb: select over the project's case matrix and print the report
-- card. @test all@ runs the whole matrix; @test \<case\>@ runs the single case
-- with that id (an unknown id fails fast, listing the valid ids). The bare binary
-- ships an empty matrix, so @test all@ prints @0/0 passed@; a project supplies its
-- matrix and seams as the 'TestSuite' threaded through
-- 'HostBootstrap.CLI.runHostBootstrapCLI'.
testCommand :: String -> TestSuite -> Mod CommandFields (IO ())
testCommand progName suite =
  command
    "test"
    ( info
        (runTests <$> caseArg)
        (progDesc "Run a project test case, or `all` for the whole matrix")
    )
  where
    caseArg =
      strArgument
        ( metavar "CASE"
            <> help ("test case id to run, or `" ++ allCasesSelector ++ "` for the whole matrix")
        )
    runTests selector = gate progName Context.TestWorkflowCommand [] $ do
      outcome <- runSuiteSelection suite selector
      either die (putStr . reportCard) outcome

-- | The @check-code@ verb: the fail-fast image-build quality gate. Its body is
-- project-defined; the bare binary has no project checks and passes.
checkCodeCommand :: String -> Mod CommandFields (IO ())
checkCodeCommand progName =
  command
    "check-code"
    ( info
        (pure (gate progName Context.CheckCodeCommand [] (putStrLn "check-code: no project checks defined (override in the project binary)")))
        (progDesc "Run the project's fail-fast code-check gate (project-defined body)")
    )

-- | The @config@ command group: decode and inspect the static-base
-- @hostbootstrap.dhall@ via the in-process decoder.
configCommand :: String -> Mod CommandFields (IO ())
configCommand progName =
  command
    "config"
    ( info
        (hsubparser (showCmd <> schemaCmd <> renderCmd))
        (progDesc "Decode, inspect, and generate hostbootstrap Dhall configs")
    )
  where
    showCmd =
      command
        "show"
        ( info
            (showAction <$> fileArg)
            (progDesc "Decode a hostbootstrap.dhall and print its fields")
        )
    showAction path = do
      staticBase <- decodeStaticBaseFile path
      putStr (renderStaticBase staticBase)

    schemaCmd =
      command
        "schema"
        ( info
            (pure (gate progName Context.ConfigGenerationCommand [] schemaAction))
            (progDesc "Print the Dhall schema the binary's decoders accept (the in-scope artifact union)")
        )
    schemaAction = putStrLn (T.unpack (schemaUnion coreArtifacts))

    renderCmd =
      command
        "render"
        ( info
            (gate progName Context.ConfigGenerationCommand [] . renderAction <$> optional artifactOpt)
            (progDesc "Render concrete Dhall configs from the reusable vocabulary")
        )
    artifactOpt =
      strOption (long "artifact" <> metavar "NAME" <> help "render only the named artifact")
    renderAction mname =
      let arts = case mname of
            Nothing -> coreArtifacts
            Just n -> filter ((== T.pack n) . artifactName) coreArtifacts
       in putStr (concatMap renderOne arts)
    renderOne a = T.unpack (artifactName a) <> ":\n" <> T.unpack (renderText a) <> "\n\n"

-- | The @context@ command group: explicit binary-context materialization
-- surfaces. Container creation is a bootstrap entrypoint; VM and service
-- creation derive from the active parent context before crossing a boundary.
contextCommand :: String -> Mod CommandFields (IO ())
contextCommand progName =
  command
    "context"
    ( info
        (hsubparser (createCmd <> showPathCmd))
        (progDesc "Create or inspect binary-context configs")
    )
  where
    createCmd =
      command
        "create"
        ( info
            (hsubparser (vmCmd <> containerCmd <> serviceCmd))
            (progDesc "Create a binary-context config for a nested context")
        )
    vmCmd =
      command
        "vm"
        ( info
            (createDerived Context.VMOrchestrator Context.deriveVMContext <$> outputArg <*> optional sourceRootOpt)
            (progDesc "Create a VM-orchestrator binary-context config from the active context")
        )
    containerCmd =
      command
        "container"
        ( info
            (createContainer <$> outputArg <*> optional sourceRootOpt <*> optional cpuOpt <*> optional memoryOpt <*> optional storageOpt)
            (progDesc "Create a project-container binary-context config")
        )
    serviceCmd =
      command
        "service"
        ( info
            (createDerived Context.ClusterService Context.deriveServiceContext <$> outputArg <*> optional sourceRootOpt)
            (progDesc "Create a cluster-service binary-context config from the active context")
        )
    showPathCmd =
      command
        "path"
        ( info
            (pure (putStrLn "project-binary-context-config.dhall"))
            (progDesc "Print the canonical binary-context filename")
        )

    createContainer out mroot mcpu mmemory mstorage = do
      root <- maybe getCurrentDirectory pure mroot
      let envelope =
            case (mcpu, mmemory, mstorage) of
              (Nothing, Nothing, Nothing) -> Context.defaultResourceEnvelope
              _ ->
                Context.ResourceEnvelope
                  (maybe 0 id mcpu)
                  (maybe (T.pack "0GiB") T.pack mmemory)
                  (maybe (T.pack "0GiB") T.pack mstorage)
          ctx =
            Context.standaloneContainerContext
              (T.pack progName)
              (T.pack progName)
              (T.pack root)
              envelope
      Context.writeContextFile out ctx

    createDerived kind derive out mroot = do
      root <- maybe getCurrentDirectory pure mroot
      Context.withSiblingContext (T.pack progName) Context.ContextCreationCommand [] $ \parent -> do
        unless (kind `elem` Context.childContextKinds parent) $
          die ("binary context: child context " ++ show kind ++ " is not allowed in " ++ show (Context.contextKind parent))
        Context.writeContextFile out (derive parent (T.pack root))

    outputArg =
      strArgument
        ( metavar "OUTPUT"
            <> help "path to write project-binary-context-config.dhall"
        )
    sourceRootOpt =
      strOption (long "source-root" <> metavar "DIR" <> help "source root recorded in the context")
    cpuOpt =
      option auto (long "cpu" <> metavar "N" <> help "CPU envelope for the created context")
    memoryOpt =
      strOption (long "memory" <> metavar "TEXT" <> help "memory envelope for the created context")
    storageOpt =
      strOption (long "storage" <> metavar "TEXT" <> help "storage envelope for the created context")

-- | The @cluster@ command group: kind/Helm lifecycle within the cordoned budget.
clusterCommand :: String -> Mod CommandFields (IO ())
clusterCommand progName =
  command
    "cluster"
    ( info
        (hsubparser (upCmd <> downCmd <> deleteCmd <> statusCmd))
        (progDesc "Bring the cluster up/down/delete/status within the cordoned resource budget")
    )
  where
    upCmd =
      command
        "up"
        (info (pure runUp) (progDesc "Bring the stack up (idempotent), cordoned to the context budget"))
    downCmd =
      command
        "down"
        (info (pure runDown) (progDesc "Tear the cluster down; preserve host .data"))
    deleteCmd =
      command
        "delete"
        (info (pure runDelete) (progDesc "Delete derived cluster state; preserve host .data"))
    statusCmd =
      command
        "status"
        (info (pure runStatus) (progDesc "Report the cluster status (read-only)"))

    runUp = withClusterContext $ \cfg ctx ->
      clusterUp cfg (planForContext ctx) (resourcesFromEnvelope (Context.resourceEnvelope ctx))
    runDown = withClusterContext $ \cfg ctx ->
      clusterDown cfg (planForContext ctx)
    runDelete = withClusterContext $ \cfg ctx ->
      clusterDelete cfg (planForContext ctx)
    runStatus = withClusterContext $ \cfg ctx ->
      clusterStatus cfg (planForContext ctx)

    withClusterContext run =
      Context.withSiblingContext (T.pack progName) Context.ClusterLifecycleCommand [] $ \ctx -> do
        cfg <- hostConfig
        withCurrentDirectory (T.unpack (Context.sourceRoot ctx)) (run cfg ctx)

hostConfig :: IO HostConfig
hostConfig = do
  detected <- detect
  case detected of
    Left err -> die err
    Right sub -> buildHostConfig sub

-- | A @FILE@ argument defaulting to @hostbootstrap.dhall@.
fileArg :: Parser FilePath
fileArg =
  strArgument
    ( metavar "FILE"
        <> value "hostbootstrap.dhall"
        <> showDefault
        <> help "path to the static-base hostbootstrap.dhall"
    )

-- | The production cluster plan, rooted at the active context's source root.
planForContext :: Context.BinaryContext -> ClusterPlan
planForContext ctx =
  resolvePlan (T.unpack (Context.project ctx)) (T.unpack (Context.sourceRoot ctx)) Production

resourcesFromEnvelope :: Context.ResourceEnvelope -> Resources
resourcesFromEnvelope envelope =
  Resources (Context.cpu envelope) (Context.memory envelope) (Context.storage envelope)
