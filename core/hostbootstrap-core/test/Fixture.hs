{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
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
    deriveProjectConfigForKind,
    projectConfigForRole,
    initArgsFor,
    projectInit,
)
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import HostBootstrap.Config.Class (
    InitArgs (..),
    ProjectCfg (..),
    TestCfg (..),
    withProjectCodec,
    withMappedProjectCodec,
 )
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
import HostBootstrap.Harness (VariantId, mkTestMatrix, mkVariantId, variantDraft)
import Numeric.Natural (Natural)

data Resources = Resources
    { cpu :: Natural
    , memory :: Text
    , storage :: Text
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

newtype DeployConfig = DeployConfig
    { haReplicas :: Natural
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

newtype TestConfig = TestConfig
    { testResources :: Resources
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

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

instance ProjectCfg FixtureProject ProjectConfig where
    withProductionProjectCodec =
        withProjectCodec "fixture/Production" projectConfigCodec
    withHarnessProjectCodec _ =
        withProjectCodec "fixture/Harness" projectConfigCodec
    cfgContext = context

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

instance ProjectCfg SecretFixtureProject SecretProjectConfig where
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
     in baseCfg{context = foldr Context.addRole baseCfg.context args.alsoRoles}

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
        , force = False
        , ifMissing = False
        }
