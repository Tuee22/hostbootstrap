{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Project-local @<project>.dhall@ schema and its in-process decoder.
--
-- The supported config contract is binary-owned: Python derives the project
-- name from the Cabal file and never reads or writes Dhall. Normal binary
-- commands read a sibling project config, validate the runtime context inside
-- it, and then dispatch.
module HostBootstrap.Config.Schema
  ( ProjectConfig (..),
    DeployConfig (..),
    Resources (..),
    decodeProjectConfigText,
    decodeProjectConfigFile,
    writeProjectConfigFile,
    renderProjectConfig,
    projectConfigSchemaText,
    projectConfigSnapshotHash,
    renderProjectConfigSnapshotLog,
    renderProjectConfigSummary,
    validateProjectConfigForProject,
    defaultResources,
    defaultDeployConfig,
    defaultProjectConfig,
    configRoleNames,
    parseConfigRole,
    renderConfigRole,
    projectConfigFileName,
    projectConfigPathForExecutable,
    siblingProjectConfigPath,
    requireSiblingProjectConfig,
    withSiblingProjectConfigContext,
    projectConfigForRole,
    projectConfigFromContext,
    deriveProjectConfigForKind,
    resourceEnvelopeFromResources,
    resourcesFromEnvelope,
  )
where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.Bits (xor)
import Data.Char (ord)
import Data.Word (Word64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Dhall (FromDhall, auto, inputFile)
import qualified Dhall
import qualified Dhall.Core
import Dhall.Marshal.Encode (Encoder (declared))
import GHC.Generics (Generic)
import HostBootstrap.Context (BinaryContext)
import qualified HostBootstrap.Context as Context
import qualified HostBootstrap.Dhall.Hoist as Hoist
import Numeric (showHex)
import Numeric.Natural (Natural)
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)

-- | The per-project resource budget.
data Resources = Resources
  { cpu :: Natural,
    memory :: Text,
    storage :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, Dhall.ToDhall)

-- | Project deployment knobs that are authored at the host level and projected
-- into narrower child configs when a boundary is crossed.
data DeployConfig = DeployConfig
  { haReplicas :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall, Dhall.ToDhall)

-- | The supported project-local config shape.
--
-- Project identity is deliberately not a top-level field; it is derived by the
-- bootstrapper from the Cabal file. Runtime identity is part of the nested
-- context and is validated against the derived project/binary name before
-- normal command dispatch.
data ProjectConfig = ProjectConfig
  { dockerfile :: Text,
    resources :: Resources,
    context :: BinaryContext,
    deploy :: DeployConfig
  }
  deriving (Eq, Show, Generic, FromDhall, Dhall.ToDhall)

-- | Decode a project-local config from Dhall source text.
decodeProjectConfigText :: Text -> IO ProjectConfig
decodeProjectConfigText = Dhall.input auto

-- | Decode a project-local config from a @<project>.dhall@ file.
decodeProjectConfigFile :: FilePath -> IO ProjectConfig
decodeProjectConfigFile = inputFile auto

-- | Write a project-local config as deterministic Dhall source.
writeProjectConfigFile :: FilePath -> ProjectConfig -> IO ()
writeProjectConfigFile path cfg = TIO.writeFile path (renderProjectConfig cfg <> "\n")

-- | Render a project-local config to Dhall source text. The repeated vocabulary
-- unions are hoisted into top-level @let@ bindings (shared with 'Context.renderContext'
-- via 'Context.vocabUnions') so the generated config stays compact and standalone.
renderProjectConfig :: ProjectConfig -> Text
renderProjectConfig = Hoist.renderHoisted Context.vocabUnions

-- | The reflected Dhall type accepted by the project-local config decoder.
projectConfigSchemaText :: Text
projectConfigSchemaText = Dhall.Core.pretty (declared (Dhall.inject :: Encoder ProjectConfig))

-- | The editable resource defaults emitted by @config init@.
defaultResources :: Resources
defaultResources = Resources {cpu = 4, memory = "8GiB", storage = "20GiB"}

-- | The editable deploy defaults emitted by @config init@.
defaultDeployConfig :: DeployConfig
defaultDeployConfig = DeployConfig {haReplicas = 1}

-- | User-facing role names accepted by @config init --role@.
configRoleNames :: [Text]
configRoleNames =
  [ "host-orchestrator",
    "vm-orchestrator",
    "vm-project-container",
    "cluster-service",
    "daemon",
    "one-shot-job",
    "test-harness"
  ]

-- | Render the canonical role name for a context kind.
renderConfigRole :: Context.ContextKind -> Text
renderConfigRole = Context.defaultRoleName

-- | The canonical local config filename for a project.
projectConfigFileName :: Text -> FilePath
projectConfigFileName projectName = T.unpack projectName ++ ".dhall"

-- | Where a project-local config lives for a known executable path.
projectConfigPathForExecutable :: Text -> FilePath -> FilePath
projectConfigPathForExecutable projectName exe =
  takeDirectory exe </> projectConfigFileName projectName

-- | The project-local config path for the currently running executable.
siblingProjectConfigPath :: Text -> IO FilePath
siblingProjectConfigPath projectName =
  projectConfigPathForExecutable projectName <$> getExecutablePath

-- | Parse a user-facing role name for generated local configs.
parseConfigRole :: String -> Either String Context.ContextKind
parseConfigRole raw =
  case normalise (T.pack raw) of
    "host" -> Right Context.HostOrchestrator
    "host-orchestrator" -> Right Context.HostOrchestrator
    "vm" -> Right Context.VMOrchestrator
    "vm-orchestrator" -> Right Context.VMOrchestrator
    "container" -> Right Context.VMProjectContainer
    "ad-hoc-container" -> Right Context.VMProjectContainer
    "vm-project-container" -> Right Context.VMProjectContainer
    "service" -> Right Context.ClusterService
    "cluster-service" -> Right Context.ClusterService
    "daemon" -> Right Context.Daemon
    "one-shot" -> Right Context.OneShotJob
    "one-shot-job" -> Right Context.OneShotJob
    "test" -> Right Context.TestHarness
    "test-harness" -> Right Context.TestHarness
    other ->
      Left $
        "unknown config role "
          <> T.unpack other
          <> " (expected one of: "
          <> T.unpack (T.intercalate ", " configRoleNames)
          <> ")"
  where
    normalise = T.replace "_" "-" . T.toLower . T.strip

-- | Convert user-facing resources into the runtime authority envelope.
resourceEnvelopeFromResources :: Resources -> Context.ResourceEnvelope
resourceEnvelopeFromResources Resources {cpu = resourceCpu, memory = resourceMemory, storage = resourceStorage} =
  Context.ResourceEnvelope
    { Context.cpu = resourceCpu,
      Context.memory = resourceMemory,
      Context.storage = resourceStorage
    }

-- | Convert a runtime authority envelope back into the project-level resource
-- shape used by generated child configs.
resourcesFromEnvelope :: Context.ResourceEnvelope -> Resources
resourcesFromEnvelope envelope =
  Resources
    { cpu = Context.cpu envelope,
      memory = Context.memory envelope,
      storage = Context.storage envelope
    }

-- | Build a project-local config for a selected local role.
projectConfigForRole ::
  Text ->
  Text ->
  Text ->
  Text ->
  Resources ->
  DeployConfig ->
  Context.ContextKind ->
  ProjectConfig
projectConfigForRole projectName binaryName root cfgDockerfile cfgResources cfgDeploy kind =
  ProjectConfig
    { dockerfile = cfgDockerfile,
      resources = cfgResources,
      context =
        Context.contextForKind
          projectName
          binaryName
          root
          (resourceEnvelopeFromResources cfgResources)
          kind,
      deploy = cfgDeploy
    }

-- | Build the default config emitted by @config init@.
defaultProjectConfig :: Text -> Text -> Context.ContextKind -> ProjectConfig
defaultProjectConfig projectName root =
  projectConfigForRole projectName projectName root "docker/Dockerfile" defaultResources defaultDeployConfig

-- | Wrap an already-derived context in the project-local config shape.
projectConfigFromContext :: Text -> DeployConfig -> Context.BinaryContext -> ProjectConfig
projectConfigFromContext cfgDockerfile cfgDeploy cfgContext =
  ProjectConfig
    { dockerfile = cfgDockerfile,
      resources = resourcesFromEnvelope (Context.resourceEnvelope cfgContext),
      context = cfgContext,
      deploy = cfgDeploy
    }

-- | Project a parent config into a narrower child config for a boundary crossing.
deriveProjectConfigForKind :: Context.ContextKind -> ProjectConfig -> Text -> Either String ProjectConfig
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
      { dockerfile = parentDockerfile,
        context = parentContext,
        deploy = parentDeploy
      } = parent
    projected = Right . projectConfigFromContext parentDockerfile parentDeploy

-- | A short human-readable summary of a decoded project-local config.
renderProjectConfigSummary :: ProjectConfig -> String
renderProjectConfigSummary
  ProjectConfig
    { dockerfile = cfgDockerfile,
      resources = cfgResources,
      context = cfgContext,
      deploy = cfgDeploy
    } =
  T.unpack $
    T.unlines
      [ "project:      " <> Context.project cfgContext,
        "binary:       " <> Context.binary cfgContext,
        "dockerfile:   " <> cfgDockerfile,
        "context-kind: " <> T.pack (show (Context.contextKind cfgContext)),
        "role:         " <> Context.roleName cfgContext,
        "resources:    cpu="
          <> T.pack (show (cpu cfgResources))
          <> " memory="
          <> memory cfgResources
          <> " storage="
          <> storage cfgResources,
        "ha-replicas:  " <> T.pack (show (haReplicas cfgDeploy))
      ]

-- | Stable, non-secret fingerprint for startup logging. This is not a
-- cryptographic digest; it exists to correlate a process with the exact config
-- snapshot it loaded.
projectConfigSnapshotHash :: Text -> Text
projectConfigSnapshotHash content =
  T.pack ("fnv64:" ++ leftPad16 (showHex (T.foldl' step offset content) ""))
  where
    offset :: Word64
    offset = 14695981039346656037

    prime :: Word64
    prime = 1099511628211

    step :: Word64 -> Char -> Word64
    step h ch = (h `xor` fromIntegral (ord ch)) * prime

    leftPad16 :: String -> String
    leftPad16 value = replicate (max 0 (16 - length value)) '0' ++ value

-- | One-line daemon/service startup metadata. It intentionally includes only
-- authority and placement metadata, not secrets.
renderProjectConfigSnapshotLog :: FilePath -> Text -> BinaryContext -> Text
renderProjectConfigSnapshotLog path configHash cfgContext =
  T.unwords
    [ "project-config-snapshot",
      "project=" <> Context.project cfgContext,
      "binary=" <> Context.binary cfgContext,
      "contextKind=" <> T.pack (show (Context.contextKind cfgContext)),
      "roleName=" <> Context.roleName cfgContext,
      "configPath=" <> T.pack path,
      "configHash=" <> configHash,
      "sourceRoot=" <> Context.sourceRoot cfgContext,
      "cpu=" <> T.pack (show (Context.cpu envelope)),
      "memory=" <> Context.memory envelope,
      "storage=" <> Context.storage envelope
    ]
  where
    envelope = Context.resourceEnvelope cfgContext

-- | Validate that the runtime context inside the config belongs to the derived
-- project/binary identity.
validateProjectConfigForProject :: Text -> ProjectConfig -> Either String ProjectConfig
validateProjectConfigForProject expected cfg
  | Context.project (context cfg) /= expected =
      Left $
        "project config: expected project "
          <> T.unpack expected
          <> ", got "
          <> T.unpack (Context.project (context cfg))
  | Context.binary (context cfg) /= expected =
      Left $
        "project config: expected binary "
          <> T.unpack expected
          <> ", got "
          <> T.unpack (Context.binary (context cfg))
  | otherwise = Right cfg

-- | Load and validate the current executable's sibling project config.
requireSiblingProjectConfig ::
  Text ->
  Context.CommandClass ->
  [Context.Capability] ->
  IO ProjectConfig
requireSiblingProjectConfig projectName cls caps =
  fst <$> loadSiblingProjectConfig projectName cls caps

-- | Run an action with a validated sibling project config and its nested
-- runtime context.
withSiblingProjectConfigContext ::
  Text ->
  Context.CommandClass ->
  [Context.Capability] ->
  (ProjectConfig -> BinaryContext -> IO a) ->
  IO a
withSiblingProjectConfigContext projectName cls caps action = do
  (cfg, cfgContext) <- loadSiblingProjectConfig projectName cls caps
  action cfg cfgContext

loadSiblingProjectConfig ::
  Text ->
  Context.CommandClass ->
  [Context.Capability] ->
  IO (ProjectConfig, BinaryContext)
loadSiblingProjectConfig projectName cls caps = do
  path <- siblingProjectConfigPath projectName
  exists <- doesFileExist path
  if not exists
    then
      failProjectConfig
        path
        ("missing " ++ path ++ "; run `" ++ T.unpack projectName ++ " config init`")
    else do
      rawResult <- try (TIO.readFile path) :: IO (Either SomeException Text)
      raw <- case rawResult of
        Left err -> failProjectConfig path ("failed to read " ++ path ++ ": " ++ firstLine (show err))
        Right content -> pure content
      decoded <- try (decodeProjectConfigFile path) :: IO (Either SomeException ProjectConfig)
      cfg <- case decoded of
        Left err -> failProjectConfig path ("failed to decode " ++ path ++ ": " ++ firstLine (show err))
        Right value -> pure value
      case validateProjectConfigForProject projectName cfg of
        Left err -> failProjectConfig path err
        Right validCfg ->
          case Context.validateContext (Context.contextRequirement projectName cls caps) (context validCfg) of
            Left err -> do
              hPutStrLn stderr (Context.contextErrorMessage err)
              exitWith (ExitFailure 1)
            Right cfgContext -> do
              when (shouldLogSnapshot cls cfgContext) $
                TIO.hPutStrLn
                  stderr
                  (renderProjectConfigSnapshotLog path (projectConfigSnapshotHash raw) cfgContext)
              pure (validCfg, cfgContext)
  where
    firstLine = takeWhile (/= '\n')
    failProjectConfig _ detail = do
      hPutStrLn stderr ("project config: " ++ detail)
      exitWith (ExitFailure 1)

    shouldLogSnapshot commandClass cfgContext =
      commandClass `elem` [Context.DaemonCommand, Context.ServiceCommand]
        || Context.contextKind cfgContext `elem` [Context.Daemon, Context.ClusterService]
