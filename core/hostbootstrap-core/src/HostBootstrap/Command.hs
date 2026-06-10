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
  ( StaticBase (..),
    decodeStaticBaseFile,
    renderStaticBase,
  )
import HostBootstrap.Dhall.Gen
  ( ConfigArtifact (..),
    coreArtifacts,
    schemaUnion,
  )
import HostBootstrap.Harness (TestSuite, allCasesSelector, reportCard, runSuiteSelection)
import HostBootstrap.Ensure (Reconciler, ensureCommand)
import qualified HostBootstrap.Ensure.Colima as Colima
import qualified HostBootstrap.Ensure.Cuda as Cuda
import qualified HostBootstrap.Ensure.Docker as Docker
import qualified HostBootstrap.Ensure.Ghc as Ghc
import qualified HostBootstrap.Ensure.Homebrew as Homebrew
import qualified HostBootstrap.Ensure.Incus as Incus
import qualified HostBootstrap.Ensure.Tart as Tart
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.Substrate (detect)
import qualified Data.Text as T
import Options.Applicative
import System.Exit (die)
import System.FilePath (takeDirectory)

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
coreCommands :: TestSuite -> [Mod CommandFields (IO ())]
coreCommands suite =
  [ ensureCommand allReconcilers,
    configCommand,
    clusterCommand,
    testCommand suite,
    checkCodeCommand
  ]

-- | The @test@ verb: select over the project's case matrix and print the report
-- card. @test all@ runs the whole matrix; @test \<case\>@ runs the single case
-- with that id (an unknown id fails fast, listing the valid ids). The bare binary
-- ships an empty matrix, so @test all@ prints @0/0 passed@; a project supplies its
-- matrix and seams as the 'TestSuite' threaded through
-- 'HostBootstrap.CLI.runHostBootstrapCLI'.
testCommand :: TestSuite -> Mod CommandFields (IO ())
testCommand suite =
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
    runTests selector = do
      outcome <- runSuiteSelection suite selector
      either die (putStr . reportCard) outcome

-- | The @check-code@ verb: the fail-fast image-build quality gate. Its body is
-- project-defined; the bare binary has no project checks and passes.
checkCodeCommand :: Mod CommandFields (IO ())
checkCodeCommand =
  command
    "check-code"
    ( info
        (pure (putStrLn "check-code: no project checks defined (override in the project binary)"))
        (progDesc "Run the project's fail-fast code-check gate (project-defined body)")
    )

-- | The @config@ command group: decode and inspect the static-base
-- @hostbootstrap.dhall@ via the in-process decoder.
configCommand :: Mod CommandFields (IO ())
configCommand =
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
            (pure schemaAction)
            (progDesc "Print the Dhall schema the binary's decoders accept (the in-scope artifact union)")
        )
    schemaAction = putStrLn (T.unpack (schemaUnion coreArtifacts))

    renderCmd =
      command
        "render"
        ( info
            (renderAction <$> optional artifactOpt)
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

-- | The @cluster@ command group: kind/Helm lifecycle within the cordoned budget.
clusterCommand :: Mod CommandFields (IO ())
clusterCommand =
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
        (info (runUp <$> fileArg) (progDesc "Bring the stack up (idempotent), cordoned to the budget"))
    downCmd =
      command
        "down"
        (info (runDown <$> fileArg) (progDesc "Tear the cluster down; preserve host .data"))
    deleteCmd =
      command
        "delete"
        (info (runDelete <$> fileArg) (progDesc "Delete derived cluster state; preserve host .data"))
    statusCmd =
      command
        "status"
        (info (runStatus <$> fileArg) (progDesc "Report the cluster status (read-only)"))

    runUp path = withContext path $ \cfg staticBase ->
      clusterUp cfg (planFor path staticBase) (resources staticBase)
    runDown path = withContext path $ \cfg staticBase ->
      clusterDown cfg (planFor path staticBase)
    runDelete path = withContext path $ \cfg staticBase ->
      clusterDelete cfg (planFor path staticBase)
    runStatus path = withContext path $ \cfg staticBase ->
      clusterStatus cfg (planFor path staticBase)

-- | A @FILE@ argument defaulting to @hostbootstrap.dhall@.
fileArg :: Parser FilePath
fileArg =
  strArgument
    ( metavar "FILE"
        <> value "hostbootstrap.dhall"
        <> showDefault
        <> help "path to the static-base hostbootstrap.dhall"
    )

-- | Decode the config, detect the substrate, and build the resolved host
-- configuration before running a cluster action.
withContext :: FilePath -> (HostConfig -> StaticBase -> IO ()) -> IO ()
withContext path run = do
  staticBase <- decodeStaticBaseFile path
  detected <- detect
  case detected of
    Left err -> die err
    Right sub -> do
      cfg <- buildHostConfig sub
      run cfg staticBase

-- | The production cluster plan, rooted at the config file's directory.
planFor :: FilePath -> StaticBase -> ClusterPlan
planFor path staticBase =
  resolvePlan (T.unpack (project staticBase)) (takeDirectory path) Production
