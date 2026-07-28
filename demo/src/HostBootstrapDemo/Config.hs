{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

{- | The hostbootstrap-demo's own project-config shape and its in-process
decoder/renderer.

These types used to live in @hostbootstrap-core@'s @Config.Schema@. The core is
now generic over a project's config type (the 'ProjectCfg' class, coupled to the
core only through the embedded 'Context.BinaryContext'), so the **project** owns
its actual @<project>.dhall@ record. This module is the demo's instance: the
@ProjectConfig@ / @Resources@ / @DeployConfig@ / @TestConfig@ records, the
project-specific render/decode helpers, the child-projection logic, and — the one
place defaults live — the @InitArgs@ builders ('demoInit' / 'demoTestInit' /
'demoTestConfig') the demo's 'HostBootstrap.CLI.ProjectSpec' threads in.
-}
module HostBootstrapDemo.Config (
    DemoProject,
    ProjectConfig (..),
    DeployConfig (..),
    Resources,
    cpu,
    memory,
    storage,
    mkResources,
    Quantity,
    quantityText,
    mkQuantity,
    HaReplicas,
    haReplicasNat,
    mkHaReplicas,
    Port,
    portNat,
    mkPort,
    TimeoutSeconds,
    timeoutSecondsNat,
    mkTimeoutSeconds,
    TestConfig (..),
    ServiceType (..),
    WebServiceConfig (..),
    AcceleratorServiceConfig (..),
    configuredServiceVariant,
    maxAcceleratorRequestTimeoutSeconds,

    -- * Render / decode
    projectConfigCodec,
    testConfigCodec,
    renderDhallText,
    renderProjectConfig,
    decodeProjectConfigText,
    decodeProjectConfigFile,
    projectConfigSchemaText,
    renderProjectConfigSummary,
    renderTestConfig,
    decodeTestConfigText,
    decodeTestConfigFile,
    testConfigSchemaText,

    -- * Resource conversions
    envelopeOfResources,

    -- * Construction
    projectConfigForRole,
    projectConfigFromContext,
    deriveProjectConfigForKind,
    defaultTestConfig,

    -- * Defaults (the one place defaults live)
    demoDefaultResources,
    demoDefaultDeployConfig,
    demoDefaultDockerfile,
    demoDefaultMessage,
    demoDefaultWebServiceConfig,
    demoDefaultAcceleratorServiceConfig,
    demoDefaultProjectConfig,

    -- * InitArgs builders (threaded into the demo's ProjectSpec)
    demoInit,
    demoTestInit,
    demoAssemble,
)
where

import Data.Either (fromRight)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall (autoWith), ToDhall)
import qualified Dhall
import Dhall.Marshal.Decode (Decoder (Decoder, expected, extract), extractError, fromMonadic, toMonadic)
import GHC.Generics (Generic)
import HostBootstrap.Cluster.Cordon (parseQuantity)
import HostBootstrap.Config.Class (
    AssemblyRequest (..),
    ConfigAssembly,
    ProjectCfg (..),
    TestCfg (..),
    failConfigAssembly,
    pureConfigAssembly,
    withProjectCodec,
 )
import qualified HostBootstrap.Config.Class as Config
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
import HostBootstrap.Harness (
    CaseId,
    TestMatrix,
    TestMatrixError,
    VariantId,
    mkTestMatrix,
    mkVariantId,
    variantDraft,
    variantDraftValue,
 )
import Numeric.Natural (Natural)

{- | Refine a base 'Decoder' at DECODE time (development_plan_standards § BB/§ O):
decode the underlying value, then validate it, failing the Dhall **extract** (not a
runtime @die@) when it violates the contract — so an unworkable @<project>.dhall@ /
@test.dhall@ is rejected at decode rather than accepted-then-failed at bring-up. The
matching 'ToDhall' stays transparent (each newtype encodes its underlying
@Text@/@Natural@ via @deriving newtype ToDhall@), so the reflected @service schema@
and the golden are **unchanged**: these types are decode-time refinements only.
-}
refiningDecoder :: Decoder a -> (a -> Either String b) -> Decoder b
refiningDecoder base refine =
    Decoder
        { extract = \expr -> fromMonadic $ do
            a <- toMonadic (extract base expr)
            either (toMonadic . extractError . T.pack) Right (refine a)
        , expected = expected base
        }

{- | A typed Kubernetes-style resource quantity (memory / storage). Its hidden
constructor and 'mkQuantity' validate through the one canonical
'parseQuantity', so neither decoded nor programmatically assembled config can
carry a bad unit. The transparent 'ToDhall' encodes the underlying 'Text', so
the schema is unchanged.
-}
newtype Quantity = Quantity {quantityText :: Text}
    deriving stock (Eq)
    deriving newtype (Show, ToDhall)

mkQuantity :: Text -> Either String Quantity
mkQuantity value =
    case parseQuantity value of
        Right _ -> Right (Quantity value)
        Left err -> Left ("invalid resource quantity " ++ show (T.unpack value) ++ ": " ++ err)

instance FromDhall Quantity where
    autoWith n = refiningDecoder (autoWith n) mkQuantity

{- | @haReplicas@ bounded to the demo's single-HA invariant (**exactly 1**): the
'FromDhall' and public smart constructor reject every other value. There is no
'Num' instance: callers cannot bypass the refinement with an overloaded
literal.
-}
newtype HaReplicas = HaReplicas {haReplicasNat :: Natural}
    deriving stock (Eq)
    deriving newtype (Show, Ord, ToDhall)

mkHaReplicas :: Natural -> Either String HaReplicas
mkHaReplicas replicas
    | replicas == 1 = Right (HaReplicas replicas)
    | otherwise = Left ("haReplicas must be exactly 1 (the demo runs a single HA replica), got " ++ show replicas)

instance FromDhall HaReplicas where
    autoWith n = refiningDecoder (autoWith n) mkHaReplicas

{- | A service port bounded to @1..65535@ at every construction boundary. The
constructor and numeric instances are intentionally unavailable. Cross-field
distinctness stays a 'validateServiceType' check (a single newtype cannot
express "these two differ").
-}
newtype Port = Port {portNat :: Natural}
    deriving stock (Eq)
    deriving newtype (Show, Ord, ToDhall)

mkPort :: Natural -> Either String Port
mkPort port
    | port >= 1 && port <= 65535 = Right (Port port)
    | otherwise = Left ("service port must be between 1 and 65535, got " ++ show port)

instance FromDhall Port where
    autoWith n = refiningDecoder (autoWith n) mkPort

-- | The accelerator request timeout bounded to @1..30@ seconds.
newtype TimeoutSeconds = TimeoutSeconds {timeoutSecondsNat :: Natural}
    deriving stock (Eq)
    deriving newtype (Show, Ord, ToDhall)

mkTimeoutSeconds :: Natural -> Either String TimeoutSeconds
mkTimeoutSeconds timeoutSeconds
    | timeoutSeconds >= 1 && timeoutSeconds <= maxAcceleratorRequestTimeoutSeconds =
        Right (TimeoutSeconds timeoutSeconds)
    | otherwise = Left ("requestTimeoutSeconds must be between 1 and 30, got " ++ show timeoutSeconds)

instance FromDhall TimeoutSeconds where
    autoWith n = refiningDecoder (autoWith n) mkTimeoutSeconds

{- | The per-project resource budget. @memory@/@storage@ are typed 'Quantity's
(unit-validated at decode). A custom 'FromDhall' additionally enforces the resource
floor (@cpu ≥ 1@) so a below-floor budget is rejected at decode, not accepted then
failed at bring-up (§ BB). 'ToDhall' is the transparent generic derivation (the Dhall
type stays @{ cpu : Natural, memory : Text, storage : Text }@).
-}
data Resources = Resources
    { cpu :: Natural
    , memory :: Quantity
    , storage :: Quantity
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (ToDhall)

mkResources :: Natural -> Text -> Text -> Either String Resources
mkResources resourceCpu resourceMemory resourceStorage
    | resourceCpu < 1 = Left "resources.cpu must be at least 1 (the lifecycle resource floor)"
    | otherwise =
        Resources resourceCpu
            <$> mkQuantity resourceMemory
            <*> mkQuantity resourceStorage

instance FromDhall Resources where
    autoWith n = refiningDecoder base validate
      where
        base =
            Dhall.record
                ( Resources
                    <$> Dhall.field "cpu" (autoWith n)
                    <*> Dhall.field "memory" (autoWith n)
                    <*> Dhall.field "storage" (autoWith n)
                )
        validate r
            | cpu r >= 1 = Right r
            | otherwise = Left "resources.cpu must be at least 1 (the lifecycle resource floor)"

{- | Project deployment knobs that are authored at the host level and projected
into narrower child configs when a boundary is crossed.
-}
newtype DeployConfig = DeployConfig
    { haReplicas :: HaReplicas
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

{- | The per-project @test.dhall@ shape (development_plan_standards § Z): the
selectable suites (the case ids plus @all@) plus the **test-config resource
overrides** projected into the test stack's config. The file is generated by
@test init@ and read by @test run@ (which builds the run config from it).
-}
newtype TestConfig = TestConfig
    { testResources :: Resources
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

instance TestCfg TestConfig where
    type TestVariant TestConfig = Text
    projectTestMatrix = demoTestMatrix

{- | Parameters owned by the demo's web service variant. They are deliberately
part of the Dhall ADT payload rather than hidden in the handler registry. The
ports are bounded 'Port's (1..65535 at decode).
-}
data WebServiceConfig = WebServiceConfig
    { publicPort :: Port
    , acceleratorPort :: Port
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

-- | Parameters owned by the accelerator daemon variant.
newtype AcceleratorServiceConfig = AcceleratorServiceConfig
    { requestTimeoutSeconds :: TimeoutSeconds
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

-- | Maximum worker deadline; the web dispatch deadline adds a ten-second cleanup/transport margin.
maxAcceleratorRequestTimeoutSeconds :: Natural
maxAcceleratorRequestTimeoutSeconds = 30

-- | The closed service family used by role-wire/schema projections.
data ServiceType
    = Web WebServiceConfig
    | Accelerator AcceleratorServiceConfig
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

{- | The supported project-local config shape.

Project identity is deliberately not a top-level field; it is derived by the
bootstrapper from the Cabal file. Runtime identity is part of the nested
context and is validated against the derived project/binary name before
normal command dispatch.
-}

-- | Type-level identity for the installed demo project.
data DemoProject

data ProjectConfig scope = ProjectConfig
    { dockerfile :: Text
    , resources :: Resources
    , context :: BinaryContext
    , deploy :: DeployConfig
    , message :: Text
    , webServiceConfig :: WebServiceConfig
    , acceleratorServiceConfig :: AcceleratorServiceConfig
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

{- | The demo's 'ProjectCfg' instance: the core reaches the embedded context
through one read-only projection and otherwise never touches the demo's fields.
-}
instance ProjectCfg DemoProject ProjectConfig where
    withProductionProjectCodec =
        withProjectCodec
            "HostBootstrapDemo.ProjectConfig/Production"
            projectConfigCodec
    withHarnessProjectCodec _ =
        withProjectCodec
            "HostBootstrapDemo.ProjectConfig/Harness"
            projectConfigCodec
    cfgContext = context

configuredServiceVariant :: ProjectConfig scope -> Either String String
configuredServiceVariant cfg =
    case Context.contextKind (context cfg) of
        Context.ClusterService ->
            validateServiceType (Web (webServiceConfig cfg))
        Context.Daemon ->
            validateServiceType (Accelerator (acceleratorServiceConfig cfg))
        _ -> Left "service selection requires a ClusterService or Daemon leaf context"

validateServiceType :: ServiceType -> Either String String
validateServiceType (Web (WebServiceConfig public accelerator))
    | not (validPort public) = Left "Web publicPort must be between 1 and 65535"
    | not (validPort accelerator) = Left "Web acceleratorPort must be between 1 and 65535"
    | public == accelerator = Left "Web publicPort and acceleratorPort must be distinct"
    | otherwise = Right "web"
  where
    validPort port = portNat port >= 1 && portNat port <= 65535
validateServiceType (Accelerator (AcceleratorServiceConfig timeoutSeconds))
    | timeoutSecondsNat timeoutSeconds < 1 = Left "Accelerator requestTimeoutSeconds must be positive"
    | timeoutSecondsNat timeoutSeconds > maxAcceleratorRequestTimeoutSeconds = Left "Accelerator requestTimeoutSeconds must not exceed 30"
    | otherwise = Right "accelerator"

{- | Render a project-local config to Dhall source text, hoisting the repeated
vocabulary unions into top-level @let@ bindings.
-}
renderProjectConfig :: ProjectConfig scope -> Text
renderProjectConfig = renderHoistedValue projectConfigCodec Context.vocabUnions

-- | The one admitted decoder/encoder pair for the project-local config.
projectConfigCodec :: CodecWitness (ProjectConfig scope)
projectConfigCodec =
    requireCodecWitness "HostBootstrapDemo.ProjectConfig" autoCodecWitness

-- | The one admitted decoder/encoder pair for @test.dhall@.
testConfigCodec :: CodecWitness TestConfig
testConfigCodec =
    requireCodecWitness "HostBootstrapDemo.TestConfig" (autoCodecWitness @TestConfig)

textCodec :: CodecWitness Text
textCodec =
    requireCodecWitness "Text" (autoCodecWitness @Text)

-- | Render a Dhall @Text@ literal using Dhall's own encoder.
renderDhallText :: Text -> Text
renderDhallText = renderValue textCodec

-- | Decode a project-local config from Dhall source text.
decodeProjectConfigText :: Text -> IO (ProjectConfig scope)
decodeProjectConfigText = decodeText projectConfigCodec

-- | Decode a project-local config from a @<project>.dhall@ file.
decodeProjectConfigFile :: FilePath -> IO (ProjectConfig scope)
decodeProjectConfigFile = decodeFile projectConfigCodec

-- | The reflected Dhall type accepted by the project-local config decoder.
projectConfigSchemaText :: Text
projectConfigSchemaText = codecSchemaText projectConfigCodec

-- | The reflected Dhall type the @test.dhall@ decoder accepts.
testConfigSchemaText :: Text
testConfigSchemaText = codecSchemaText testConfigCodec

-- | Render a @test.dhall@ to deterministic Dhall source via its @ToDhall@ embedding.
renderTestConfig :: TestConfig -> Text
renderTestConfig = renderValue testConfigCodec

-- | Decode a @test.dhall@.
decodeTestConfigFile :: FilePath -> IO TestConfig
decodeTestConfigFile = decodeFile testConfigCodec

-- | Decode a @test.dhall@ from Dhall source text.
decodeTestConfigText :: Text -> IO TestConfig
decodeTestConfigText = decodeText testConfigCodec

{- | The default @test.dhall@: the project's selectable suites plus the resource
override (seeded from the project config's resources).
-}
defaultTestConfig :: Resources -> TestConfig
defaultTestConfig res = TestConfig{testResources = res}

-- | Convert user-facing resources into the runtime authority envelope.
envelopeOfResources :: Resources -> Context.ResourceEnvelope
envelopeOfResources Resources{cpu = resourceCpu, memory = resourceMemory, storage = resourceStorage} =
    Context.ResourceEnvelope
        { Context.cpu = resourceCpu
        , Context.memory = quantityText resourceMemory
        , Context.storage = quantityText resourceStorage
        }

{- | Build a project-local config for a selected local role. The @message@ is
the config-driven worked example the webservice serves (Sprint 20.1).
-}
projectConfigForRole ::
    Text ->
    Text ->
    Text ->
    Text ->
    Resources ->
    DeployConfig ->
    Text ->
    Context.ContextKind ->
    ProjectConfig scope
projectConfigForRole projectName binaryName root cfgDockerfile cfgResources cfgDeploy cfgMessage kind =
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
        , message = cfgMessage
        , webServiceConfig = demoDefaultWebServiceConfig
        , acceleratorServiceConfig = demoDefaultAcceleratorServiceConfig
        }

{- | Wrap an already-derived context in the project-local config shape. The
@message@ is forwarded from the parent so child frames carry the same served
message (Sprint 20.1).
-}
projectConfigFromContext :: ProjectConfig parentScope -> Context.BinaryContext -> ProjectConfig scope
projectConfigFromContext
    ProjectConfig
        { dockerfile = parentDockerfile
        , resources = parentResources
        , deploy = parentDeploy
        , message = parentMessage
        , webServiceConfig = parentWebServiceConfig
        , acceleratorServiceConfig = parentAcceleratorServiceConfig
        }
    cfgContext' =
        ProjectConfig
            { dockerfile = parentDockerfile
            , resources = parentResources
            , context = cfgContext'
            , deploy = parentDeploy
            , message = parentMessage
            , webServiceConfig = parentWebServiceConfig
            , acceleratorServiceConfig = parentAcceleratorServiceConfig
            }

-- | Project a parent config into a narrower child config for a boundary crossing.
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
    parentContext = context parent
    projected = Right . projectConfigFromContext parent

-- | A short human-readable summary of a decoded project-local config.
renderProjectConfigSummary :: ProjectConfig scope -> String
renderProjectConfigSummary
    cfg@ProjectConfig
        { dockerfile = cfgDockerfile
        , resources = cfgResources
        , context = cfgContext'
        , deploy = cfgDeploy
        , message = cfgMessage
        } =
        T.unpack $
            T.unlines
                [ "project:      " <> Context.project cfgContext'
                , "binary:       " <> Context.binary cfgContext'
                , "dockerfile:   " <> cfgDockerfile
                , "context-kind: " <> T.pack (show (Context.contextKind cfgContext'))
                , "role:         " <> Context.roleName cfgContext'
                , "resources:    cpu="
                    <> T.pack (show cfgResources.cpu)
                    <> " memory="
                    <> quantityText cfgResources.memory
                    <> " storage="
                    <> quantityText cfgResources.storage
                , "ha-replicas:  " <> T.pack (show cfgDeploy.haReplicas)
                , "message:      " <> cfgMessage
                , "service:      " <> T.pack (fromRight "none" (configuredServiceVariant cfg))
                ]

-- ---------------------------------------------------------------------------
-- Defaults + InitArgs builders (the one place config defaults live).
-- ---------------------------------------------------------------------------

-- | The demo project name, derived from the Cabal file.
demoProjectName :: Text
demoProjectName = "hostbootstrap-demo"

{- | The demo's resource defaults (the full-lifecycle ceiling: cpu 6 / 10GiB /
80GiB). Core ships **no** resource defaults; this is the demo's.
-}
demoDefaultResources :: Resources
demoDefaultResources = builtIn "default resources" (mkResources 6 "10GiB" "80GiB")

-- | The demo's deploy defaults (one HA replica). Core ships no deploy defaults.
demoDefaultDeployConfig :: DeployConfig
demoDefaultDeployConfig = DeployConfig{haReplicas = builtIn "default HA replicas" (mkHaReplicas 1)}

-- | The demo's default Dockerfile path. Core ships no Dockerfile default.
demoDefaultDockerfile :: Text
demoDefaultDockerfile = "docker/Dockerfile"

{- | The demo's default served @message@ (the config-driven worked example, Sprint
20.1): @project init@ seeds it, the webservice reads it from its mounted config and
serves it, and the SPA renders it in the @#message@ element. Core ships none.
-}
demoDefaultMessage :: Text
demoDefaultMessage = "Hello, world!"

demoDefaultWebServiceConfig :: WebServiceConfig
demoDefaultWebServiceConfig =
    WebServiceConfig
        (builtIn "default public port" (mkPort 8080))
        (builtIn "default accelerator port" (mkPort 8081))

demoDefaultAcceleratorServiceConfig :: AcceleratorServiceConfig
demoDefaultAcceleratorServiceConfig =
    AcceleratorServiceConfig
        (builtIn "default accelerator timeout" (mkTimeoutSeconds 30))

builtIn :: String -> Either String a -> a
builtIn label =
    either (error . (("invalid " ++ label ++ ": ") ++)) id

{- | Canonical secret-free value used only for the separately named full-schema
Production/Harness artifacts. Runtime config still comes from assembly.
-}
demoDefaultProjectConfig :: ProjectConfig scope
demoDefaultProjectConfig =
    projectConfigForRole
        demoProjectName
        demoProjectName
        "."
        demoDefaultDockerfile
        demoDefaultResources
        demoDefaultDeployConfig
        demoDefaultMessage
        Context.HostOrchestrator

{- | The demo's @init@ builder: interpret the parsed 'InitArgs' into a concrete
'ProjectConfig', supplying the demo's defaults for every omitted knob. This is
the **only** default-bearing function (core ships none). Reused by @project init@
/ @service init@ and by 'demoTestConfig' (so the harness generates its run config
through the same builder production uses).
-}
demoInit :: Config.InitArgs -> Either String (ProjectConfig scope)
demoInit = demoInitWithMessage demoDefaultMessage

{- | The message-parameterized 'demoInit': interpret the parsed 'InitArgs' with an
explicit served @message@ (the default-bearing 'demoInit' supplies
'demoDefaultMessage'; the harness's second variant supplies its own, Sprint 20.3).
-}
demoInitWithMessage :: Text -> Config.InitArgs -> Either String (ProjectConfig scope)
demoInitWithMessage cfgMessage args = do
    cfgResources <-
        mkResources
            (fromMaybe demoDefaultResources.cpu args.mCpu)
            (fromMaybe (quantityText demoDefaultResources.memory) args.memory)
            (fromMaybe (quantityText demoDefaultResources.storage) args.storage)
    replicas <-
        maybe
            (Right demoDefaultDeployConfig.haReplicas)
            mkHaReplicas
            args.haReplicas
    let cfgDeploy = DeployConfig{haReplicas = replicas}
        cfgDockerfile = fromMaybe demoDefaultDockerfile args.dockerfile
        root = fromMaybe "." args.sourceRoot
        baseCfg =
            projectConfigForRole
                demoProjectName
                demoProjectName
                (T.pack root)
                cfgDockerfile
                cfgResources
                cfgDeploy
                cfgMessage
                args.role
        finalContext = foldr Context.addRole baseCfg.context args.alsoRoles
    pure baseCfg{context = finalContext}

{- | The demo's @test init@ builder: a 'TestConfig' seeded from the demo's default
resources and the demo's selectable suites. Needs **no** pre-existing project
config (the case-id list is fixed in the project; the resources are the demo's
defaults).
-}
demoTestInit :: Config.InitArgs -> TestConfig
demoTestInit _ = defaultTestConfig demoDefaultResources

{- | The demo's @test run@ config generator: build the run's labeled
'ProjectConfig' variants from the 'TestConfig' (host-orchestrator configs sized to
the test resources, with the demo's defaults), so the harness drives the **same**
chain interpreter production uses against configs it generated, once per variant.
Reuses 'demoInitWithMessage' so production and test share one builder.

Returns TWO variants (Sprint 20.3) whose labels are their served @message@ — the
harness threads each label into the per-variant assertion env as the expected
message, and the polymorphic Playwright asserts the SPA renders it. The first
variant uses the demo default; the second a distinct message — so a passing run
proves the served message really is config-driven (changing the config changes the
served value), not hard-coded.
-}
demoAssemble ::
    forall scope.
    AssemblyRequest DemoProject TestConfig Text scope ->
    ConfigAssembly scope (ProjectConfig scope)
demoAssemble request =
    case request of
        ProductionAssembly args ->
            either failConfigAssembly pureConfigAssembly (demoInit args)
        HarnessAssembly _ tc draft ->
            either failConfigAssembly pureConfigAssembly (configFor tc (variantDraftValue draft))
  where
    configFor :: TestConfig -> Text -> Either String (ProjectConfig scope)
    configFor tc msg =
        demoInitWithMessage
            msg
            Config.InitArgs
                { Config.role = Context.HostOrchestrator
                , Config.alsoRoles = []
                , Config.output = Nothing
                , Config.sourceRoot = Just "."
                , Config.mCpu = Just tc.testResources.cpu
                , Config.memory = Just (quantityText tc.testResources.memory)
                , Config.storage = Just (quantityText tc.testResources.storage)
                , Config.dockerfile = Just demoDefaultDockerfile
                , Config.haReplicas = Just (haReplicasNat demoDefaultDeployConfig.haReplicas)
                , Config.force = True
                , Config.ifMissing = False
                }

demoTestMatrix :: [CaseId] -> TestConfig -> Either TestMatrixError (TestMatrix Text)
demoTestMatrix caseIds _ =
    mkTestMatrix
        caseIds
        [variantDraft defaultVariantId demoDefaultMessage, variantDraft universeVariantId "Hello, Universe!"]
        [(cid, [defaultVariantId, universeVariantId]) | cid <- caseIds]
  where
    defaultVariantId = literalVariantId "hello-world"
    universeVariantId = literalVariantId "hello-universe"

literalVariantId :: Text -> VariantId
literalVariantId value =
    either (error . ("invalid built-in demo variant id: " ++) . show) id (mkVariantId value)
