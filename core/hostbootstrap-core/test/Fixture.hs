{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A core-internal project-config instance used by the core test suite.
--
-- The core is generic over a project's config type (the 'ProjectCfg' class); the
-- concrete config record lives in a consumer (the demo). The core tests need a
-- concrete 'ProjectCfg' to exercise the generic command/CLI machinery and the
-- generic sibling loader, so this module supplies a faithful in-test instance
-- (the same four-field shape the demo's @ProjectConfig@ has, so its reflected
-- Dhall schema and decode round-trips are equivalent coverage of what moved out
-- of core).
module Fixture
  ( ProjectConfig (..),
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
    deriveProjectConfigForKind,
    projectConfigForRole,
    initArgsFor,
    projectInit,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall, auto, inputFile)
import qualified Dhall
import qualified Dhall.Core
import Dhall.Marshal.Encode (Encoder (declared, embed))
import GHC.Generics (Generic)
import HostBootstrap.Config.Class (InitArgs (..), ProjectCfg (..))
import HostBootstrap.Context (BinaryContext)
import qualified HostBootstrap.Context as Context
import qualified HostBootstrap.Dhall.Hoist as Hoist
import Numeric.Natural (Natural)

data Resources = Resources
  { cpu :: Natural,
    memory :: Text,
    storage :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

newtype DeployConfig = DeployConfig
  { haReplicas :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data TestConfig = TestConfig
  { testSuites :: [Text],
    testResources :: Resources
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data ProjectConfig = ProjectConfig
  { dockerfile :: Text,
    resources :: Resources,
    context :: BinaryContext,
    deploy :: DeployConfig
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

instance ProjectCfg ProjectConfig where
  cfgContext = context
  cfgWithContext ctx cfg = cfg {context = ctx}

defaultResources :: Resources
defaultResources = Resources {cpu = 4, memory = "8GiB", storage = "20GiB"}

defaultDeployConfig :: DeployConfig
defaultDeployConfig = DeployConfig {haReplicas = 1}

defaultDockerfile :: Text
defaultDockerfile = "docker/Dockerfile"

envelopeOfResources :: Resources -> Context.ResourceEnvelope
envelopeOfResources r =
  Context.ResourceEnvelope
    { Context.cpu = r.cpu,
      Context.memory = r.memory,
      Context.storage = r.storage
    }

resourcesFromEnvelope :: Context.ResourceEnvelope -> Resources
resourcesFromEnvelope envelope =
  Resources
    { cpu = Context.cpu envelope,
      memory = Context.memory envelope,
      storage = Context.storage envelope
    }

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
          (envelopeOfResources cfgResources)
          kind,
      deploy = cfgDeploy
    }

projectConfigFromContext :: Text -> DeployConfig -> Context.BinaryContext -> ProjectConfig
projectConfigFromContext cfgDockerfile cfgDeploy cfgContext' =
  ProjectConfig
    { dockerfile = cfgDockerfile,
      resources = resourcesFromEnvelope (Context.resourceEnvelope cfgContext'),
      context = cfgContext',
      deploy = cfgDeploy
    }

defaultProjectConfig :: Text -> Text -> Context.ContextKind -> ProjectConfig
defaultProjectConfig projectName root =
  projectConfigForRole projectName projectName root defaultDockerfile defaultResources defaultDeployConfig

defaultTestConfig :: [Text] -> Resources -> TestConfig
defaultTestConfig suites res = TestConfig {testSuites = suites, testResources = res}

renderProjectConfig :: ProjectConfig -> Text
renderProjectConfig = Hoist.renderHoisted Context.vocabUnions

decodeProjectConfigText :: Text -> IO ProjectConfig
decodeProjectConfigText = Dhall.input auto

decodeProjectConfigFile :: FilePath -> IO ProjectConfig
decodeProjectConfigFile = inputFile auto

renderTestConfig :: TestConfig -> Text
renderTestConfig cfg = Dhall.Core.pretty (embed (Dhall.inject :: Encoder TestConfig) cfg)

decodeTestConfigText :: Text -> IO TestConfig
decodeTestConfigText = Dhall.input auto

projectConfigSchemaText :: Text
projectConfigSchemaText = Dhall.Core.pretty (declared (Dhall.inject :: Encoder ProjectConfig))

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
      { dockerfile = parentDockerfile,
        context = parentContext,
        deploy = parentDeploy
      } = parent
    projected = Right . projectConfigFromContext parentDockerfile parentDeploy

-- | The fixture's @init@ builder (mirrors the demo's @demoInit@), the only
-- default-bearing function: interpret the parsed flags into a 'ProjectConfig',
-- filling omitted knobs from the fixture defaults.
projectInit :: Text -> InitArgs -> ProjectConfig
projectInit projectName args =
  let cfgResources =
        Resources
          { cpu = fromMaybe defaultResources.cpu args.mCpu,
            memory = fromMaybe defaultResources.memory args.memory,
            storage = fromMaybe defaultResources.storage args.storage
          }
      cfgDeploy = DeployConfig {haReplicas = fromMaybe defaultDeployConfig.haReplicas args.haReplicas}
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
   in baseCfg {context = foldr Context.addRole baseCfg.context args.alsoRoles}

-- | A defaultless 'InitArgs' for a chosen role (used by the spec builders).
initArgsFor :: Context.ContextKind -> InitArgs
initArgsFor kind =
  InitArgs
    { role = kind,
      alsoRoles = [],
      output = Nothing,
      sourceRoot = Just "/workspace/demo",
      mCpu = Nothing,
      memory = Nothing,
      storage = Nothing,
      dockerfile = Nothing,
      haReplicas = Nothing,
      force = False,
      ifMissing = False
    }
