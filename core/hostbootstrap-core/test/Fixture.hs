{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
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
    fixtureExecutableName,
    withFixtureInstalledProject,
    withFixtureProjectRoot,
    withFixtureProjectPlan,
    withFixtureProjectPlanContext,
    withFixtureHarnessAuthority,
)
where

import Control.Monad (foldM)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Config.Class (
    InitArgs (..),
    ProjectCfg (..),
    TestCfg (..),
    withMappedProjectCodec,
    withProjectCodec,
 )
import HostBootstrap.Config.Schema (withValidatedConfig)
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
import HostBootstrap.Harness (VariantId, mkTestMatrix, mkVariantId, runWithOwnedRun, variantDraft)
import HostBootstrap.Harness.Ownership (
    protectedProjectRunOwnership,
    withOwnedHarnessRoot,
 )
import HostBootstrap.Lifecycle.Mode (
    harnessRootHarnessAuthority,
    productionActiveMode,
    productionRootAuthority,
    productionRootModeLease,
    productionRootUnboundLease,
    withProductionLifecycleProfile,
    withProductionRoot,
 )
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    planDraftsFromValidatedBuilder,
 )
import HostBootstrap.ProjectPlan.Construct (withProjectPlan)
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import HostBootstrap.Protected (openProtectedStore)
import HostBootstrap.Step (StepPlan)
import Numeric.Natural (Natural)
import System.Environment (getExecutablePath)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

{- | Acquire a real protected generative Harness root for authority-sensitive
tests. The helper fails if acquisition or finalization does not settle; it never
mints authority from a caller-selected run name.
-}
withFixtureHarnessAuthority ::
    forall result.
    ( forall projectId runId.
      Authority.InstalledProjectIdentity projectId ->
      V.HarnessAuthority projectId runId ->
      IO result
    ) ->
    IO result
withFixtureHarnessAuthority use =
    withFixtureInstalledProject $ \project ->
        withSystemTempDirectory "hostbootstrap-harness-authority" $ \root -> do
            rooted <-
                withCanonicalProjectRoot root root $ \canonicalRoot ->
                    runWithOwnedRun
                        ( protectedProjectRunOwnership
                            project
                            canonicalRoot
                            root
                            (root </> ".test_data")
                        )
                        ( \owned ->
                            withOwnedHarnessRoot owned $ \_store _project harnessRoot _closeControl ->
                                use project (harnessRootHarnessAuthority harnessRoot)
                        )
            outcome <- either (ioError . userError . show) pure rooted
            case outcome of
                Left reason -> ioError (userError reason)
                Right (result, Nothing) -> pure result
                Right (_, Just failure) ->
                    ioError (userError ("harness authority cleanup failed: " ++ show failure))

-- | The executable-verified name used by the core test binary.
fixtureExecutableName :: IO Text
fixtureExecutableName = Authority.normalizeExecutableIdentity <$> getExecutablePath

{- | Admit the actual test executable identity without allowing its generative
@projectId@ to escape the continuation.
-}
withFixtureInstalledProject ::
    (forall projectId. Authority.InstalledProjectIdentity projectId -> IO result) ->
    IO result
withFixtureInstalledProject use = do
    name <- fixtureExecutableName
    admitted <- Authority.withInstalledProjectIdentity name use
    either
        (ioError . userError . T.unpack . Authority.authorityErrorMessage)
        pure
        admitted

{- | Admit one real Production project plan for projection/reconciliation
tests while keeping every generated identity inside the callback.
-}
withFixtureProjectPlan ::
    StepPlan ->
    ( forall projectId specDigest planId configId.
      ProjectPlan
        (V.Production projectId)
        specDigest
        planId
        configId
        ProjectConfig ->
      IO result
    ) ->
    IO result
withFixtureProjectPlan stepPlan use =
    withFixtureProjectPlanContext id stepPlan (\plan _context -> use plan)

{- | Admit one real Production project plan whose validated configuration
retains the exact context selected from the fixture's canonical host context.

The selected context is returned beside the plan so a test can feed that exact
value to 'HostBootstrap.ProjectPlan.Frame.withCurrentFrame'.  Child-frame tests
select it with 'Context.deriveVMContext' and 'Context.deriveContainerContext';
the compatibility wrapper above selects the root context unchanged.
-}
withFixtureProjectPlanContext ::
    (BinaryContext -> BinaryContext) ->
    StepPlan ->
    ( forall projectId specDigest planId configId.
      ProjectPlan
        (V.Production projectId)
        specDigest
        planId
        configId
        ProjectConfig ->
      BinaryContext ->
      IO result
    ) ->
    IO result
withFixtureProjectPlanContext selectContext stepPlan use =
    withSystemTempDirectory "hostbootstrap-fixture-project-plan" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
        withFixtureInstalledProject $ \project -> do
            rooted <-
                withCanonicalProjectRoot
                    (directory </> "fixture.dhall")
                    "."
                    ( \root ->
                        withProductionRoot store project Authority.ProjectUp $ \productionRoot -> do
                            opened <-
                                withProductionLifecycleProfile
                                    (Authority.rootScopeAuthority (productionRootAuthority productionRoot))
                                    (productionActiveMode (productionRootModeLease productionRoot))
                                    (productionRootUnboundLease productionRoot)
                                    ( \profile ->
                                        withProductionProjectCodec @ProjectConfig $ \codec -> do
                                            let rootValue =
                                                    defaultProjectConfig
                                                        (Authority.installedProjectName project)
                                                        (T.pack (canonicalProjectRootPath root))
                                                        Context.HostOrchestrator
                                                exactContext = selectContext rootValue.context
                                                value = rootValue{context = exactContext}
                                            validated <-
                                                withValidatedConfig codec value $ \_wire config -> do
                                                    drafts <-
                                                        either
                                                            (fail . show)
                                                            pure
                                                            ( planDraftsFromValidatedBuilder
                                                                root
                                                                config
                                                                (\_ _ -> Right stepPlan)
                                                            )
                                                    action <-
                                                        either
                                                            (fail . show)
                                                            pure
                                                            ( withProjectPlan
                                                                profile
                                                                root
                                                                config
                                                                drafts
                                                                (\plan -> use plan exactContext)
                                                            )
                                                    action
                                            either fail pure validated
                                    )
                            result <- either (fail . show) id opened
                            pure (Right result)
                    )
            modeResult <- either (fail . show) pure rooted
            either (fail . show) pure modeResult

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

instance ProjectCfg ProjectConfig where
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

instance ProjectCfg SecretProjectConfig where
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
     in case foldM (flip Context.addRole) baseCfg.context args.alsoRoles of
            Left err -> error (Context.contextErrorMessage err)
            Right ctx -> baseCfg{context = ctx}

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

{- | Admit a throwaway 'CanonicalProjectRoot' for tests that need the root the
plan is built under (§ X). It goes through the production
'withCanonicalProjectRoot' bracket against a real directory rather than
fabricating the opaque value, which the type does not permit anyway.
-}
withFixtureProjectRoot ::
    (forall rootScope rootId. CanonicalProjectRoot rootScope rootId -> IO a) ->
    IO a
withFixtureProjectRoot action =
    withSystemTempDirectory "hostbootstrap-fixture-root" $ \dir -> do
        outcome <- withCanonicalProjectRoot (dir </> "fixture.dhall") "." action
        either (fail . show) pure outcome
