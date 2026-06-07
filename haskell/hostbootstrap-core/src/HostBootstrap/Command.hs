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

import HostBootstrap.Cluster.Cordon (colimaSizingArgs, kindNodeLimits)
import HostBootstrap.Cluster.Lifecycle
  ( ClusterPlan,
    ClusterProfile (Production),
    clusterDelete,
    clusterDown,
    clusterUp,
    resolvePlan,
  )
import HostBootstrap.Config.Schema
  ( Skeleton (..),
    decodeSkeletonFile,
    renderSkeleton,
  )
import HostBootstrap.Ensure (Reconciler, ensureCommand)
import qualified HostBootstrap.Ensure.Colima as Colima
import qualified HostBootstrap.Ensure.Cuda as Cuda
import qualified HostBootstrap.Ensure.Docker as Docker
import qualified HostBootstrap.Ensure.Ghc as Ghc
import qualified HostBootstrap.Ensure.Homebrew as Homebrew
import qualified HostBootstrap.Ensure.Tart as Tart
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.Substrate (detect, isAppleSilicon)
import qualified Data.Text as T
import Options.Applicative
import System.Exit (die)
import System.FilePath (takeDirectory)

-- | The six concrete @ensure@ reconcilers.
allReconcilers :: [Reconciler]
allReconcilers =
  [ Docker.reconciler,
    Colima.reconciler,
    Cuda.reconciler,
    Homebrew.reconciler,
    Ghc.reconciler,
    Tart.reconciler
  ]

-- | The core subcommands every @hostbootstrap@-derived binary exposes.
coreCommands :: [Mod CommandFields (IO ())]
coreCommands =
  [ ensureCommand allReconcilers,
    configCommand,
    clusterCommand
  ]

-- | The @config@ command group: decode and inspect the skeletal
-- @hostbootstrap.dhall@ via the in-process decoder.
configCommand :: Mod CommandFields (IO ())
configCommand =
  command
    "config"
    ( info
        (hsubparser showCmd)
        (progDesc "Decode and inspect the skeletal hostbootstrap.dhall")
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
      skeleton <- decodeSkeletonFile path
      putStr (renderSkeleton skeleton)

-- | The @cluster@ command group: kind/Helm lifecycle within the cordoned budget.
clusterCommand :: Mod CommandFields (IO ())
clusterCommand =
  command
    "cluster"
    ( info
        (hsubparser (upCmd <> downCmd <> deleteCmd))
        (progDesc "Bring the cluster up/down/delete within the cordoned resource budget")
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

    runUp path = withContext path $ \cfg skeleton -> do
      reportCordon cfg skeleton
      clusterUp cfg (planFor path skeleton)
    runDown path = withContext path $ \cfg skeleton ->
      clusterDown cfg (planFor path skeleton)
    runDelete path = withContext path $ \cfg skeleton ->
      clusterDelete cfg (planFor path skeleton)

-- | A @FILE@ argument defaulting to @hostbootstrap.dhall@.
fileArg :: Parser FilePath
fileArg =
  strArgument
    ( metavar "FILE"
        <> value "hostbootstrap.dhall"
        <> showDefault
        <> help "path to the skeletal hostbootstrap.dhall"
    )

-- | Decode the config, detect the substrate, and build the resolved host
-- configuration before running a cluster action.
withContext :: FilePath -> (HostConfig -> Skeleton -> IO ()) -> IO ()
withContext path run = do
  skeleton <- decodeSkeletonFile path
  detected <- detect
  case detected of
    Left err -> die err
    Right sub -> do
      cfg <- buildHostConfig sub
      run cfg skeleton

-- | The production cluster plan, rooted at the config file's directory.
planFor :: FilePath -> Skeleton -> ClusterPlan
planFor path skeleton =
  resolvePlan (T.unpack (project skeleton)) (takeDirectory path) Production

-- | Report the cordon plan for the detected substrate.
reportCordon :: HostConfig -> Skeleton -> IO ()
reportCordon cfg skeleton =
  if isAppleSilicon (hcSubstrate cfg)
    then case colimaSizingArgs (resources skeleton) of
      Right args -> putStrLn ("cordon (Apple/Colima): colima " ++ unwords args)
      Left err -> die ("cordon: " ++ err)
    else case kindNodeLimits (resources skeleton) of
      Right limits -> putStrLn ("cordon (Linux/kind node limits): " ++ show limits)
      Left err -> die ("cordon: " ++ err)
