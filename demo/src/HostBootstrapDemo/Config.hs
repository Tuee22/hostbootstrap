{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

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
    ProjectConfig (..),
    DeployConfig (..),
    Resources (..),
    Quantity (..),
    HaReplicas (..),
    Port (..),
    TimeoutSeconds (..),
    TestConfig (..),
    ServiceType (..),
    WebServiceConfig (..),
    AcceleratorServiceConfig (..),
    configuredServiceVariant,
    maxAcceleratorRequestTimeoutSeconds,

    -- * Render / decode
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
    resourcesFromEnvelope,

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
    demoCaseIds,

    -- * InitArgs builders (threaded into the demo's ProjectSpec)
    demoInit,
    demoTestInit,
    demoTestConfig,
)
where

import Data.Maybe (fromMaybe)
import Data.String (IsString)
import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall (autoWith), ToDhall, auto, field, inputFile, record)
import qualified Dhall
import qualified Dhall.Core
import Dhall.Marshal.Decode (Decoder (Decoder, expected, extract), extractError, fromMonadic, toMonadic)
import Dhall.Marshal.Encode (Encoder (declared, embed))
import GHC.Generics (Generic)
import HostBootstrap.Cluster.Cordon (parseQuantity)
import HostBootstrap.Config.Class (InitArgs (..), ProjectCfg (..))
import HostBootstrap.Context (BinaryContext)
import qualified HostBootstrap.Context as Context
import qualified HostBootstrap.Dhall.Hoist as Hoist
import Numeric.Natural (Natural)

{- | Refine a base 'Decoder' at DECODE time (development_plan_standards § BB/§ O):
decode the underlying value, then validate it, failing the Dhall **extract** (not a
runtime @die@) when it violates the contract — so an unworkable @<project>.dhall@ /
@test.dhall@ is rejected at decode rather than accepted-then-failed at bring-up. The
matching 'ToDhall' stays transparent (each newtype encodes its underlying
@Text@/@Natural@ via @deriving newtype ToDhall@), so the reflected @context schema@
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

{- | A typed Kubernetes-style resource quantity (memory / storage). Its 'FromDhall'
validates the unit at DECODE via the one canonical 'parseQuantity', so a bad unit
(@"lots"@, @"10Gitten"@) fails to decode rather than only at bring-up. 'IsString'
constructs known-good internal literals; the transparent 'ToDhall' encodes the
underlying 'Text', so the schema is unchanged. (Replaces the former @Text@
memory/storage fields — legacy-tracking-for-deletion.md.)
-}
newtype Quantity = Quantity {quantityText :: Text}
    deriving stock (Eq)
    deriving newtype (Show, IsString, ToDhall)

instance FromDhall Quantity where
    autoWith n = refiningDecoder (autoWith n) validate
      where
        validate t = case parseQuantity t of
            Right _ -> Right (Quantity t)
            Left err -> Left ("invalid resource quantity " ++ show (T.unpack t) ++ ": " ++ err)

{- | @haReplicas@ bounded to the demo's single-HA invariant (**exactly 1**): the
'FromDhall' rejects any other value at decode, so a decoded config satisfies
@validateAcceleratorReplicaCount@ by construction. 'Num' lets internal code write the
literal @1@; the transparent 'ToDhall' encodes the underlying 'Natural'.
-}
newtype HaReplicas = HaReplicas {haReplicasNat :: Natural}
    deriving stock (Eq)
    deriving newtype (Show, Ord, Num, Real, Enum, Integral, ToDhall)

instance FromDhall HaReplicas where
    autoWith n = refiningDecoder (autoWith n) validate
      where
        validate r
            | r == (1 :: Natural) = Right (HaReplicas r)
            | otherwise = Left ("haReplicas must be exactly 1 (the demo runs a single HA replica), got " ++ show r)

{- | A service port bounded to @1..65535@ at decode. 'Num'/'Integral' let internal
literals and @fromIntegral port@ (Warp wants an 'Int') work unchanged; transparent
'ToDhall'. Cross-field distinctness stays a 'validateServiceType' check (a single
newtype cannot express "these two differ").
-}
newtype Port = Port {portNat :: Natural}
    deriving stock (Eq)
    deriving newtype (Show, Ord, Num, Real, Enum, Integral, ToDhall)

instance FromDhall Port where
    autoWith n = refiningDecoder (autoWith n) validate
      where
        validate p
            | p >= 1 && p <= 65535 = Right (Port p)
            | otherwise = Left ("service port must be between 1 and 65535, got " ++ show p)

-- | The accelerator request timeout bounded to @1..30@ seconds at decode.
newtype TimeoutSeconds = TimeoutSeconds {timeoutSecondsNat :: Natural}
    deriving stock (Eq)
    deriving newtype (Show, Ord, Num, Real, Enum, Integral, ToDhall)

instance FromDhall TimeoutSeconds where
    autoWith n = refiningDecoder (autoWith n) validate
      where
        validate s
            | s >= 1 && s <= maxAcceleratorRequestTimeoutSeconds = Right (TimeoutSeconds s)
            | otherwise = Left ("requestTimeoutSeconds must be between 1 and 30, got " ++ show s)

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
data TestConfig = TestConfig
    { testSuites :: [Text]
    , testResources :: Resources
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

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

{- | The demo's real Dhall service sum. The config carries this ADT; the core sees
only 'configuredServiceVariant' through the generic ProjectSpec seam.
-}
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
data ProjectConfig = ProjectConfig
    { dockerfile :: Text
    , resources :: Resources
    , context :: BinaryContext
    , deploy :: DeployConfig
    , message :: Text
    , service :: Maybe ServiceType
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

{- | The demo's 'ProjectCfg' instance: the core reaches the embedded context
through these two methods and otherwise never touches the demo's fields.
-}
instance ProjectCfg ProjectConfig where
    cfgContext = context
    cfgWithContext ctx cfg = cfg{context = ctx, service = serviceTypeForProjection (service cfg) ctx}

configuredServiceVariant :: ProjectConfig -> Either String String
configuredServiceVariant cfg = case (Context.contextKind (context cfg), service cfg) of
    (Context.ClusterService, Just serviceType@(Web _)) -> validateServiceType serviceType
    (Context.Daemon, Just serviceType@(Accelerator _)) -> validateServiceType serviceType
    (Context.ClusterService, Just (Accelerator _)) -> Left "cluster-service config declares the Accelerator variant"
    (Context.Daemon, Just (Web _)) -> Left "daemon config declares the Web variant"
    (_, Just _) -> Left "service selection requires a ClusterService or Daemon leaf context"
    (_, Nothing) -> Left "effective <project>.dhall declares no ServiceType variant"

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
renderProjectConfig :: ProjectConfig -> Text
renderProjectConfig = Hoist.renderHoisted Context.vocabUnions

-- | Render a Dhall @Text@ literal using Dhall's own encoder.
renderDhallText :: Text -> Text
renderDhallText value =
    Dhall.Core.pretty (embed (Dhall.inject :: Encoder Text) value)

-- | Decode a project-local config from Dhall source text.
decodeProjectConfigText :: Text -> IO ProjectConfig
decodeProjectConfigText = Dhall.input auto

-- | Decode a project-local config from a @<project>.dhall@ file.
decodeProjectConfigFile :: FilePath -> IO ProjectConfig
decodeProjectConfigFile = inputFile auto

-- | The reflected Dhall type accepted by the project-local config decoder.
projectConfigSchemaText :: Text
projectConfigSchemaText = Dhall.Core.pretty (declared (Dhall.inject :: Encoder ProjectConfig))

-- | The reflected Dhall type the @test.dhall@ decoder accepts.
testConfigSchemaText :: Text
testConfigSchemaText = Dhall.Core.pretty (declared (Dhall.inject :: Encoder TestConfig))

-- | Render a @test.dhall@ to deterministic Dhall source via its @ToDhall@ embedding.
renderTestConfig :: TestConfig -> Text
renderTestConfig cfg = Dhall.Core.pretty (embed (Dhall.inject :: Encoder TestConfig) cfg)

-- | Decode a @test.dhall@.
decodeTestConfigFile :: FilePath -> IO TestConfig
decodeTestConfigFile = inputFile auto

-- | Decode a @test.dhall@ from Dhall source text.
decodeTestConfigText :: Text -> IO TestConfig
decodeTestConfigText = Dhall.input auto

{- | The default @test.dhall@: the project's selectable suites plus the resource
override (seeded from the project config's resources).
-}
defaultTestConfig :: [Text] -> Resources -> TestConfig
defaultTestConfig suites res = TestConfig{testSuites = suites, testResources = res}

-- | Convert user-facing resources into the runtime authority envelope.
envelopeOfResources :: Resources -> Context.ResourceEnvelope
envelopeOfResources Resources{cpu = resourceCpu, memory = resourceMemory, storage = resourceStorage} =
    Context.ResourceEnvelope
        { Context.cpu = resourceCpu
        , Context.memory = quantityText resourceMemory
        , Context.storage = quantityText resourceStorage
        }

{- | Convert a runtime authority envelope back into the project-level resource
shape used by generated child configs.
-}
resourcesFromEnvelope :: Context.ResourceEnvelope -> Resources
resourcesFromEnvelope envelope =
    Resources
        { cpu = Context.cpu envelope
        , memory = Quantity (Context.memory envelope)
        , storage = Quantity (Context.storage envelope)
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
    ProjectConfig
projectConfigForRole projectName binaryName root cfgDockerfile cfgResources cfgDeploy cfgMessage kind =
    ProjectConfig
        { dockerfile = cfgDockerfile
        , resources = cfgResources
        , context =
            Context.contextForKind
                projectName
                binaryName
                root
                (envelopeOfResources cfgResources)
                kind
        , deploy = cfgDeploy
        , message = cfgMessage
        , service = serviceTypeForContext (Context.contextForKind projectName binaryName root (envelopeOfResources cfgResources) kind)
        }

{- | Wrap an already-derived context in the project-local config shape. The
@message@ is forwarded from the parent so child frames carry the same served
message (Sprint 20.1).
-}
projectConfigFromContext :: Text -> DeployConfig -> Text -> Maybe ServiceType -> Context.BinaryContext -> ProjectConfig
projectConfigFromContext cfgDockerfile cfgDeploy cfgMessage inheritedService cfgContext' =
    ProjectConfig
        { dockerfile = cfgDockerfile
        , resources = resourcesFromEnvelope (Context.resourceEnvelope cfgContext')
        , context = cfgContext'
        , deploy = cfgDeploy
        , message = cfgMessage
        , service = serviceTypeForProjection inheritedService cfgContext'
        }

serviceTypeForContext :: Context.BinaryContext -> Maybe ServiceType
serviceTypeForContext cfgContext' = case Context.contextKind cfgContext' of
    Context.ClusterService -> Just (Web (WebServiceConfig 8080 8081))
    Context.Daemon -> Just (Accelerator (AcceleratorServiceConfig 30))
    _ -> Nothing

serviceTypeForProjection :: Maybe ServiceType -> Context.BinaryContext -> Maybe ServiceType
serviceTypeForProjection inherited cfgContext' =
    case Context.contextKind cfgContext' of
        Context.ClusterService ->
            case inherited of
                Just serviceType@(Web _) -> Just serviceType
                _ -> Just (Web (WebServiceConfig 8080 8081))
        Context.Daemon ->
            case inherited of
                Just serviceType@(Accelerator _) -> Just serviceType
                _ -> Just (Accelerator (AcceleratorServiceConfig 30))
        Context.HostOrchestrator -> inherited
        Context.VMOrchestrator -> inherited
        Context.VMProjectContainer -> inherited
        Context.TestHarness -> inherited
        Context.ImageBuildContainer -> Nothing
        Context.OneShotJob -> Nothing

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
        , context = parentContext
        , deploy = parentDeploy
        , message = parentMessage
        , service = parentService
        } = parent
    projected = Right . projectConfigFromContext parentDockerfile parentDeploy parentMessage parentService

-- | A short human-readable summary of a decoded project-local config.
renderProjectConfigSummary :: ProjectConfig -> String
renderProjectConfigSummary
    ProjectConfig
        { dockerfile = cfgDockerfile
        , resources = cfgResources
        , context = cfgContext'
        , deploy = cfgDeploy
        , message = cfgMessage
        , service = cfgService
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
                , "service:      " <> T.pack (show cfgService)
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
demoDefaultResources = Resources{cpu = 6, memory = "10GiB", storage = "80GiB"}

-- | The demo's deploy defaults (one HA replica). Core ships no deploy defaults.
demoDefaultDeployConfig :: DeployConfig
demoDefaultDeployConfig = DeployConfig{haReplicas = 1}

-- | The demo's default Dockerfile path. Core ships no Dockerfile default.
demoDefaultDockerfile :: Text
demoDefaultDockerfile = "docker/Dockerfile"

{- | The demo's default served @message@ (the config-driven worked example, Sprint
20.1): @project init@ seeds it, the webservice reads it from its mounted config and
serves it, and the SPA renders it in the @#message@ element. Core ships none.
-}
demoDefaultMessage :: Text
demoDefaultMessage = "Hello, world!"

{- | The demo's @init@ builder: interpret the parsed 'InitArgs' into a concrete
'ProjectConfig', supplying the demo's defaults for every omitted knob. This is
the **only** default-bearing function (core ships none). Reused by @project init@
/ @service init@ and by 'demoTestConfig' (so the harness generates its run config
through the same builder production uses).
-}
demoInit :: InitArgs -> ProjectConfig
demoInit = demoInitWithMessage demoDefaultMessage

{- | The message-parameterized 'demoInit': interpret the parsed 'InitArgs' with an
explicit served @message@ (the default-bearing 'demoInit' supplies
'demoDefaultMessage'; the harness's second variant supplies its own, Sprint 20.3).
-}
demoInitWithMessage :: Text -> InitArgs -> ProjectConfig
demoInitWithMessage cfgMessage args =
    let cfgResources =
            Resources
                { cpu = fromMaybe demoDefaultResources.cpu args.mCpu
                , memory = maybe demoDefaultResources.memory Quantity args.memory
                , storage = maybe demoDefaultResources.storage Quantity args.storage
                }
        cfgDeploy = DeployConfig{haReplicas = maybe demoDefaultDeployConfig.haReplicas HaReplicas args.haReplicas}
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
        finalService = serviceTypeForRoles args.role args.alsoRoles
     in baseCfg{context = finalContext, service = finalService}

serviceTypeForRoles :: Context.ContextKind -> [Context.ContextKind] -> Maybe ServiceType
serviceTypeForRoles primary additional
    | primary == Context.Daemon =
        Just (Accelerator (AcceleratorServiceConfig 30))
    | primary == Context.ClusterService =
        Just (Web (WebServiceConfig 8080 8081))
    | otherwise = firstAdditionalService additional
  where
    firstAdditionalService [] = Nothing
    firstAdditionalService (serviceRole : roles)
        | serviceRole == Context.ClusterService = Just (Web (WebServiceConfig 8080 8081))
        | serviceRole == Context.Daemon = Just (Accelerator (AcceleratorServiceConfig 30))
        | otherwise = firstAdditionalService roles

{- | The demo's @test init@ builder: a 'TestConfig' seeded from the demo's default
resources and the demo's selectable suites. Needs **no** pre-existing project
config (the case-id list is fixed in the project; the resources are the demo's
defaults).
-}
demoTestInit :: InitArgs -> TestConfig
demoTestInit _ = defaultTestConfig demoTestSuiteIds demoDefaultResources

{- | The demo's case ids — the single source of truth the harness case matrix
('demoCases' in Commands) is also built from, so the two cannot drift.
-}
demoCaseIds :: [Text]
demoCaseIds = ["pristine-bootstrap", "web-build", "e2e-tabs", "registry-persistence"]

{- | The demo's selectable test-suite ids: the case ids plus the always-injected
@all@ selector, derived from 'demoCaseIds'.
-}
demoTestSuiteIds :: [Text]
demoTestSuiteIds = demoCaseIds <> ["all"]

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
demoTestConfig :: TestConfig -> IO [(Text, ProjectConfig)]
demoTestConfig tc =
    pure
        [ (demoDefaultMessage, configFor demoDefaultMessage)
        , ("Hello, Universe!", configFor "Hello, Universe!")
        ]
  where
    configFor msg =
        demoInitWithMessage
            msg
            InitArgs
                { role = Context.HostOrchestrator
                , alsoRoles = []
                , output = Nothing
                , sourceRoot = Just "."
                , mCpu = Just tc.testResources.cpu
                , memory = Just (quantityText tc.testResources.memory)
                , storage = Just (quantityText tc.testResources.storage)
                , dockerfile = Just demoDefaultDockerfile
                , haReplicas = Just (haReplicasNat demoDefaultDeployConfig.haReplicas)
                , force = True
                , ifMissing = False
                }
