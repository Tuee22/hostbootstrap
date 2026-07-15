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
import HostBootstrap.Config.Class (InitArgs (..))
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
    ProjectConfig (..),
    Resources (..),
    ServiceType (..),
    WebServiceConfig (..),
    configuredServiceVariant,
    decodeProjectConfigText,
    decodeTestConfigText,
    defaultTestConfig,
    demoDefaultDeployConfig,
    demoDefaultDockerfile,
    demoDefaultMessage,
    demoDefaultResources,
    demoInit,
    deriveProjectConfigForKind,
    projectConfigForRole,
    renderDhallText,
    renderProjectConfig,
    renderProjectConfigSummary,
    renderTestConfig,
 )
import HostBootstrapDemo.Container (dockerBuildArgs, projectImageTag)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | A host-orchestrator demo config built from the project role builder.
hostCfg :: ProjectConfig
hostCfg =
    projectConfigForRole
        "hostbootstrap-demo"
        "hostbootstrap-demo"
        "/workspace/demo"
        "docker/Dockerfile"
        (Resources 6 "10GiB" "80GiB")
        (DeployConfig 1)
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
            let tc = defaultTestConfig ["pristine-bootstrap", "all"] (Resources 6 "10GiB" "80GiB")
            decoded <- decodeTestConfigText (renderTestConfig tc)
            decoded @?= tc
        , testCase "Dhall text literal rendering escapes chart-injected strings" $
            renderDhallText "Hello, \"Dhall\"\\world"
                @?= "\"Hello, \\\"Dhall\\\"\\\\world\""
        , testCase "a malformed config fails with a typed error" $ do
            result <- try (decodeProjectConfigText "{ dockerfile = \"x\" }") :: IO (Either SomeException ProjectConfig)
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
            serviceCfg.service @?= Just (Web (WebServiceConfig 8080 8081))
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
            let cfg = demoInit (initArgsFor HostOrchestrator)
            cfg.resources @?= demoDefaultResources
            cfg.deploy @?= demoDefaultDeployConfig
            cfg.dockerfile @?= demoDefaultDockerfile
            cfg.message @?= demoDefaultMessage
            contextKind cfg.context @?= HostOrchestrator
            cfg.service @?= Nothing
        , testCase "Dhall ServiceType selects handlers and rejects role mismatches" $ do
            let webCfg = projectConfigForRole "hostbootstrap-demo" "hostbootstrap-demo" "/srv" "docker/Dockerfile" demoDefaultResources demoDefaultDeployConfig demoDefaultMessage ClusterService
                daemonCfg = projectConfigForRole "hostbootstrap-demo" "hostbootstrap-demo" "/srv" "docker/Dockerfile" demoDefaultResources demoDefaultDeployConfig demoDefaultMessage Daemon
            configuredServiceVariant webCfg @?= Right "web"
            configuredServiceVariant daemonCfg @?= Right "accelerator"
            assertBool "daemon context cannot select Web" $
                case configuredServiceVariant daemonCfg{service = Just (Web (WebServiceConfig 8080 8081))} of
                    Left _ -> True
                    Right _ -> False
            assertBool "cluster-service context cannot select Accelerator" $
                case configuredServiceVariant webCfg{service = Just (Accelerator (AcceleratorServiceConfig 30))} of
                    Left _ -> True
                    Right _ -> False
        , testCase "multi-role host config carries Web parameters but cannot select a service" $ do
            let cfg = demoInit (initArgsFor HostOrchestrator){alsoRoles = [ClusterService]}
            commandAllowed cfg.context ServiceCommand @?= True
            cfg.service @?= Just (Web (WebServiceConfig 8080 8081))
            assertBool "an orchestrator is not a service leaf" $
                case configuredServiceVariant cfg of
                    Left _ -> True
                    Right _ -> False
        , testCase "a primary service role wins over an additional daemon role" $ do
            let cfg = demoInit (initArgsFor ClusterService){alsoRoles = [Daemon]}
            configuredServiceVariant cfg @?= Right "web"
        , testCase "child projections preserve configured service payloads" $ do
            let webHost = hostCfg{service = Just (Web (WebServiceConfig 9090 9091))}
                acceleratorHost = hostCfg{service = Just (Accelerator (AcceleratorServiceConfig 45))}
            webVm <- expectRight (deriveProjectConfigForKind VMOrchestrator webHost "/vm/demo")
            webChild <- expectRight (deriveProjectConfigForKind ClusterService webVm "/srv/demo")
            webChild.service @?= Just (Web (WebServiceConfig 9090 9091))
            acceleratorVm <- expectRight (deriveProjectConfigForKind VMOrchestrator acceleratorHost "/vm/demo")
            daemonChild <- expectRight (deriveProjectConfigForKind Daemon acceleratorVm "/srv/demo")
            daemonChild.service @?= Just (Accelerator (AcceleratorServiceConfig 45))
        , testCase "ServiceType validates ports and request timeout before dispatch" $ do
            let webCfg = projectConfigForRole "hostbootstrap-demo" "hostbootstrap-demo" "/srv" "docker/Dockerfile" demoDefaultResources demoDefaultDeployConfig demoDefaultMessage ClusterService
                daemonCfg = projectConfigForRole "hostbootstrap-demo" "hostbootstrap-demo" "/srv" "docker/Dockerfile" demoDefaultResources demoDefaultDeployConfig demoDefaultMessage Daemon
                rejects candidate =
                    assertBool "invalid service payload was rejected" $
                        case configuredServiceVariant candidate of
                            Left _ -> True
                            Right _ -> False
            rejects webCfg{service = Just (Web (WebServiceConfig 0 8081))}
            rejects webCfg{service = Just (Web (WebServiceConfig 8080 8080))}
            rejects webCfg{service = Just (Web (WebServiceConfig 8080 65536))}
            rejects daemonCfg{service = Just (Accelerator (AcceleratorServiceConfig 0))}
            rejects daemonCfg{service = Just (Accelerator (AcceleratorServiceConfig 31))}
        , testCase "demoInit honours explicit flags over defaults" $ do
            let cfg =
                    demoInit
                        (initArgsFor ImageBuildContainer)
                            { mCpu = Just 2
                            , memory = Just "4GiB"
                            , storage = Just "12GiB"
                            , haReplicas = Just 3
                            , dockerfile = Just "demo/docker/Dockerfile"
                            }
            cfg.resources @?= Resources 2 "4GiB" "12GiB"
            cfg.deploy @?= DeployConfig 3
            cfg.dockerfile @?= "demo/docker/Dockerfile"
            contextKind cfg.context @?= ImageBuildContainer
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
        , testCase "envelope of a host config carries the resource budget" $
            resourceEnvelope (context hostCfg) @?= ResourceEnvelope 6 "10GiB" "80GiB"
        , testCase "command authority narrows across the host -> service projection" $ do
            vm <- expectRight (deriveProjectConfigForKind VMOrchestrator hostCfg "/vm/demo")
            serviceCfg <- expectRight (deriveProjectConfigForKind ClusterService vm "/srv/demo")
            commandAllowed (context hostCfg) HostOrchestratorCommand @?= True
            commandAllowed (context serviceCfg) ServiceCommand @?= True
            commandAllowed (context serviceCfg) HostOrchestratorCommand @?= False
            assertBool "service keeps the kubernetes capability" (KubernetesAPI `elem` capabilities (context serviceCfg))
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

isInfixOfS :: String -> String -> Bool
isInfixOfS needle hay = T.pack needle `T.isInfixOf` T.pack hay

expectRight :: Either String a -> IO a
expectRight = either assertFailure pure
