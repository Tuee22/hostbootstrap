{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Unit coverage for the demo's own project-config shape — the types and
helpers that used to live in @hostbootstrap-core@'s @Config.Schema@ and now
live in 'HostBootstrapDemo.Config' (the project owns its @<project>.dhall@
record now that the core is generic over a project's config type). Mirrors the
round-trip / projection / schema / docker-build coverage that moved out of the
core test suite, retargeted onto the real demo config.
-}
module ConfigSpec (tests) where

import Control.Exception (SomeException, try)
import qualified Data.Text as T
import qualified Dhall
import HostBootstrap.Config.Class (InitArgs (..))
import qualified HostBootstrap.Config.Class as Config
import HostBootstrap.Context (
    BinaryContext (..),
    Capability (..),
    CommandClass (..),
    ContextFrame (..),
    ContextKind (..),
    ProviderKind (..),
    ResourceEnvelope (..),
    TopologyFrame (..),
    commandAllowed,
 )
import HostBootstrapDemo.Config (
    AcceleratorServiceConfig (..),
    DeployConfig (..),
    HaReplicas,
    Port,
    ProjectConfig (..),
    Resources,
    TimeoutSeconds,
    WebServiceConfig (..),
    configuredServiceVariant,
    decodeProjectConfigText,
    decodeTestConfigText,
    defaultTestConfig,
    demoDefaultDeployConfig,
    demoDefaultDockerfile,
    demoDefaultMessage,
    demoDefaultAcceleratorServiceConfig,
    demoDefaultResources,
    demoDefaultWebServiceConfig,
    demoInit,
    deriveProjectConfigForKind,
    envelopeOfResources,
    mkHaReplicas,
    mkPort,
    mkResources,
    mkTimeoutSeconds,
    projectConfigForRole,
    renderDhallText,
    renderProjectConfig,
    renderProjectConfigSummary,
    renderTestConfig,
 )
import HostBootstrapDemo.Container (dockerBuildArgs, projectImageTag)
import Numeric.Natural (Natural)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | A host-orchestrator demo config built from the project role builder.
hostCfg :: ProjectConfig ()
hostCfg =
    projectConfigForRole
        "hostbootstrap-demo"
        "hostbootstrap-demo"
        "/workspace/demo"
        "docker/Dockerfile"
        (validResources 6 "10GiB" "80GiB")
        (validDeployConfig 1)
        "Hello, world!"
        HostOrchestrator

tests :: TestTree
tests =
    testGroup
        "ConfigSpec (demo)"
        [ testCase "rendered project config decodes back to the same value" $ do
            decoded <- decodeProjectConfigText (renderProjectConfig hostCfg)
            decoded @?= hostCfg
        , testCase "rendered config hoists each vocabulary union into a single let" $ do
            let rendered = renderProjectConfig hostCfg
            T.count "let ContextKind =" rendered @?= 1
            T.count "let ProviderKind =" rendered @?= 1
            T.count "let Capability =" rendered @?= 1
            T.count "let CommandClass =" rendered @?= 1
            assertBool
                "use sites reference the hoisted binding"
                ("ContextKind.HostOrchestrator" `T.isInfixOf` rendered)
        , testCase "rendered test.dhall decodes back to the same TestConfig" $ do
            let tc = defaultTestConfig (validResources 6 "10GiB" "80GiB")
            decoded <- decodeTestConfigText (renderTestConfig tc)
            decoded @?= tc
        , testCase "Dhall text literal rendering escapes chart-injected strings" $
            renderDhallText "Hello, \"Dhall\"\\world"
                @?= "\"Hello, \\\"Dhall\\\"\\\\world\""
        , testCase "a malformed config fails with a typed error" $ do
            result <-
                try (decodeProjectConfigText "{ dockerfile = \"x\" }") ::
                    IO (Either SomeException (ProjectConfig ()))
            case result of
                Left _ -> pure ()
                Right s -> assertFailure ("expected a decode error, got " ++ show s)
        , testCase "child projections preserve project settings and narrow authority" $ do
            vm <- expectRight (deriveProjectConfigForKind VMOrchestrator hostCfg "/vm/demo")
            serviceCfg <- expectRight (deriveProjectConfigForKind ClusterService vm "/srv/demo")
            vm.dockerfile @?= hostCfg.dockerfile
            serviceCfg.deploy @?= hostCfg.deploy
            vm.resources @?= hostCfg.resources
            -- The served message is forwarded down every child frame (Sprint 20.1).
            vm.message @?= hostCfg.message
            serviceCfg.message @?= hostCfg.message
            serviceCfg.webServiceConfig @?= validWebServiceConfig 8080 8081
            serviceCfg.acceleratorServiceConfig @?= validAcceleratorServiceConfig 30
            contextKind (context vm) @?= VMOrchestrator
            parentChain (context vm) @?= [ContextFrame HostOrchestrator "hostbootstrap-demo"]
            topologyFrames (context vm)
                @?= [ TopologyFrame "host-orchestrator-0" "" HostProvider HostOrchestrator "host-orchestrator"
                    , TopologyFrame "vm-orchestrator-1" "host-orchestrator-0" IncusVMProvider VMOrchestrator "vm-orchestrator"
                    ]
            contextKind (context serviceCfg) @?= ClusterService
        , testCase "child projection rejects direct host-to-runtime-container configs" $
            deriveProjectConfigForKind VMProjectContainer hostCfg "/workspace/demo"
                @?= Left "project config: child context VMProjectContainer is not allowed in HostOrchestrator"
        , testCase "demoInit fills omitted knobs with the demo defaults" $ do
            cfg <- expectRight (demoInit (initArgsFor HostOrchestrator))
            cfg.resources @?= demoDefaultResources
            cfg.deploy @?= demoDefaultDeployConfig
            cfg.dockerfile @?= demoDefaultDockerfile
            cfg.message @?= demoDefaultMessage
            contextKind cfg.context @?= HostOrchestrator
            cfg.webServiceConfig @?= validWebServiceConfig 8080 8081
            cfg.acceleratorServiceConfig @?= validAcceleratorServiceConfig 30
        , testCase "validated leaf context selects the structural service role" $ do
            let webCfg = projectConfigForRole "hostbootstrap-demo" "hostbootstrap-demo" "/srv" "docker/Dockerfile" demoDefaultResources demoDefaultDeployConfig demoDefaultMessage ClusterService
                daemonCfg = projectConfigForRole "hostbootstrap-demo" "hostbootstrap-demo" "/srv" "docker/Dockerfile" demoDefaultResources demoDefaultDeployConfig demoDefaultMessage Daemon
            configuredServiceVariant webCfg @?= Right "web"
            configuredServiceVariant daemonCfg @?= Right "accelerator"
        , testCase "an orchestrator cannot be given a service role at all (§ 15.9)" $ do
            -- This configuration used to be constructible and was refused only
            -- later, at service selection. The role addition itself is now
            -- refused, so the authority never exists to be checked.
            case demoInit (initArgsFor HostOrchestrator){alsoRoles = [ClusterService]} of
                Left refusal ->
                    assertBool
                        ("expected a role-addition refusal, got " ++ refusal)
                        ("may not acquire" `isInfixOfS` refusal)
                Right cfg ->
                    assertFailure
                        ( "an orchestrator must not acquire service authority, but got "
                            ++ show (commandAllowed cfg.context ServiceCommand)
                        )
        , testCase "a plain orchestrator still carries Web parameters and selects no service" $ do
            cfg <- expectRight (demoInit (initArgsFor HostOrchestrator))
            commandAllowed cfg.context ServiceCommand @?= False
            cfg.webServiceConfig @?= validWebServiceConfig 8080 8081
            assertBool "an orchestrator is not a service leaf" $
                case configuredServiceVariant cfg of
                    Left _ -> True
                    Right _ -> False
        , testCase "a primary service role wins over an additional daemon role" $ do
            cfg <- expectRight (demoInit (initArgsFor ClusterService){alsoRoles = [Daemon]})
            configuredServiceVariant cfg @?= Right "web"
        , testCase "child projections preserve configured service payloads" $ do
            let customWebConfig = validWebServiceConfig 9090 9091
                customAcceleratorConfig = validAcceleratorServiceConfig 20
                webHost =
                    hostCfg
                        {webServiceConfig = customWebConfig}
                acceleratorHost =
                    hostCfg
                        {acceleratorServiceConfig = customAcceleratorConfig}
            webVm <- expectRight (deriveProjectConfigForKind VMOrchestrator webHost "/vm/demo")
            webChild <- expectRight (deriveProjectConfigForKind ClusterService webVm "/srv/demo")
            webChild.webServiceConfig @?= validWebServiceConfig 9090 9091
            webChild.acceleratorServiceConfig @?= demoDefaultAcceleratorServiceConfig
            acceleratorVm <- expectRight (deriveProjectConfigForKind VMOrchestrator acceleratorHost "/vm/demo")
            daemonChild <- expectRight (deriveProjectConfigForKind Daemon acceleratorVm "/srv/demo")
            daemonChild.acceleratorServiceConfig @?= validAcceleratorServiceConfig 20
            daemonChild.webServiceConfig @?= demoDefaultWebServiceConfig
        , testCase "role parameters validate ports and request timeout before dispatch" $ do
            let webCfg = projectConfigForRole "hostbootstrap-demo" "hostbootstrap-demo" "/srv" "docker/Dockerfile" demoDefaultResources demoDefaultDeployConfig demoDefaultMessage ClusterService
                rejects candidate =
                    assertBool "invalid service payload was rejected" $
                        case configuredServiceVariant candidate of
                            Left _ -> True
                            Right _ -> False
            let rejectsWeb candidate =
                    rejects
                        webCfg
                            { webServiceConfig = candidate
                            }
            rejectsWeb (validWebServiceConfig 8080 8080)
            assertBool "zero ports cannot be constructed" (either (const True) (const False) (mkPort 0))
            assertBool "oversized ports cannot be constructed" (either (const True) (const False) (mkPort 65536))
            assertBool "zero timeouts cannot be constructed" (either (const True) (const False) (mkTimeoutSeconds 0))
            assertBool "oversized timeouts cannot be constructed" (either (const True) (const False) (mkTimeoutSeconds 31))
        , testCase "demoInit honours explicit flags over defaults" $ do
            cfg <-
                expectRight $
                    demoInit
                        (initArgsFor ImageBuildContainer)
                            { mCpu = Just 2
                            , memory = Just "4GiB"
                            , storage = Just "12GiB"
                            , haReplicas = Just 1
                            , dockerfile = Just "demo/docker/Dockerfile"
                            }
            cfg.resources @?= validResources 2 "4GiB" "12GiB"
            cfg.deploy @?= validDeployConfig 1
            cfg.dockerfile @?= "demo/docker/Dockerfile"
            contextKind cfg.context @?= ImageBuildContainer
        , testCase "demoInit rejects invalid CLI refinement inputs before assembly" $ do
            assertBool
                "invalid HA input is data"
                (either (const True) (const False) (demoInit (initArgsFor HostOrchestrator){Config.haReplicas = Just 3}))
            assertBool
                "invalid quantity input is data"
                (either (const True) (const False) (demoInit (initArgsFor HostOrchestrator){Config.memory = Just "lots"}))
        , testCase "renderProjectConfigSummary surfaces identity and budget" $ do
            let summary = renderProjectConfigSummary hostCfg
            assertBool "names the project" ("project:" `isInfixOfS` summary)
            assertBool "names the dockerfile" ("docker/Dockerfile" `isInfixOfS` summary)
            assertBool "names the ha replicas" ("ha-replicas:" `isInfixOfS` summary)
            assertBool "names the served message" ("message:" `isInfixOfS` summary)
            assertBool "surfaces the message value" ("Hello, world!" `isInfixOfS` summary)
        , testCase "projectImageTag is <project>:local" $
            projectImageTag hostCfg @?= "hostbootstrap-demo:local"
        , testCase "dockerBuildArgs builds the dockerfile FROM the base, tagged, from ." $
            dockerBuildArgs hostCfg "base:tag"
                @?= ["build", "-f", "docker/Dockerfile", "--build-arg", "BASE_IMAGE=base:tag", "-t", "hostbootstrap-demo:local", "."]
        , testCase "the sole project resource value projects to a provider envelope" $
            envelopeOfResources hostCfg.resources @?= ResourceEnvelope 6 "10GiB" "80GiB"
        , testCase "command authority narrows across the host -> service projection" $ do
            vm <- expectRight (deriveProjectConfigForKind VMOrchestrator hostCfg "/vm/demo")
            serviceCfg <- expectRight (deriveProjectConfigForKind ClusterService vm "/srv/demo")
            commandAllowed (context hostCfg) HostOrchestratorCommand @?= True
            commandAllowed (context serviceCfg) ServiceCommand @?= True
            commandAllowed (context serviceCfg) HostOrchestratorCommand @?= False
            assertBool "service keeps the kubernetes capability" (KubernetesAPI `elem` capabilities (context serviceCfg))
        , -- Type-level configuration validity (development_plan_standards § BB/§ O): an
          -- unworkable field is rejected at DECODE via the typed newtypes' validating
          -- 'FromDhall' (typed 'Quantity', bounded 'HaReplicas'/'Port'/'TimeoutSeconds',
          -- resource-floor 'Resources'), not accepted-then-failed at bring-up.
          testGroup
            "invalid config fields are rejected at decode"
            [ testCase "a valid Resources still decodes to the expected value" $ do
                r <- (Dhall.input Dhall.auto "{ cpu = 4, memory = \"8GiB\", storage = \"20GiB\" }" :: IO Resources)
                r @?= validResources 4 "8GiB" "20GiB"
            , testCase "a bad resource-quantity unit fails to decode" $
                assertDecodeFails (Dhall.input Dhall.auto "{ cpu = 4, memory = \"lots\", storage = \"20GiB\" }" :: IO Resources)
            , testCase "a below-floor cpu (0) fails to decode" $
                assertDecodeFails (Dhall.input Dhall.auto "{ cpu = 0, memory = \"8GiB\", storage = \"20GiB\" }" :: IO Resources)
            , testCase "haReplicas other than 1 fails to decode" $
                assertDecodeFails (Dhall.input Dhall.auto "{ haReplicas = 2 }" :: IO DeployConfig)
            , testCase "a valid haReplicas = 1 still decodes" $ do
                d <- (Dhall.input Dhall.auto "{ haReplicas = 1 }" :: IO DeployConfig)
                d @?= validDeployConfig 1
            , testCase "an out-of-range service port fails to decode" $
                assertDecodeFails (Dhall.input Dhall.auto "{ publicPort = 70000, acceleratorPort = 8081 }" :: IO WebServiceConfig)
            , testCase "a zero service port fails to decode" $
                assertDecodeFails (Dhall.input Dhall.auto "{ publicPort = 0, acceleratorPort = 8081 }" :: IO WebServiceConfig)
            , testCase "a request timeout above 30 fails to decode" $
                assertDecodeFails (Dhall.input Dhall.auto "{ requestTimeoutSeconds = 45 }" :: IO AcceleratorServiceConfig)
            , testCase "a request timeout of 0 fails to decode" $
                assertDecodeFails (Dhall.input Dhall.auto "{ requestTimeoutSeconds = 0 }" :: IO AcceleratorServiceConfig)
            ]
        ]

-- | A defaultless 'InitArgs' for a chosen role.
initArgsFor :: ContextKind -> InitArgs
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

validResources :: Natural -> T.Text -> T.Text -> Resources
validResources resourceCpu resourceMemory resourceStorage =
    either (error . ("invalid test resources: " ++)) id $
        mkResources resourceCpu resourceMemory resourceStorage

validHaReplicas :: Natural -> HaReplicas
validHaReplicas =
    either (error . ("invalid test HA replicas: " ++)) id . mkHaReplicas

validDeployConfig :: Natural -> DeployConfig
validDeployConfig = DeployConfig . validHaReplicas

validPort :: Natural -> Port
validPort =
    either (error . ("invalid test port: " ++)) id . mkPort

validWebServiceConfig :: Natural -> Natural -> WebServiceConfig
validWebServiceConfig public accelerator =
    WebServiceConfig (validPort public) (validPort accelerator)

validTimeoutSeconds :: Natural -> TimeoutSeconds
validTimeoutSeconds =
    either (error . ("invalid test timeout: " ++)) id . mkTimeoutSeconds

validAcceleratorServiceConfig :: Natural -> AcceleratorServiceConfig
validAcceleratorServiceConfig =
    AcceleratorServiceConfig . validTimeoutSeconds

isInfixOfS :: String -> String -> Bool
isInfixOfS needle hay = T.pack needle `T.isInfixOf` T.pack hay

-- | Assert a Dhall decode is rejected (throws), not silently accepted.
assertDecodeFails :: forall a. (Show a) => IO a -> IO ()
assertDecodeFails action = do
    result <- try action :: IO (Either SomeException a)
    case result of
        Left _ -> pure ()
        Right v -> assertFailure ("expected a decode rejection, but it decoded to " ++ show v)

expectRight :: Either String a -> IO a
expectRight = either assertFailure pure
