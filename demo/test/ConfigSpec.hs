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
    DeployConfig (..),
    ProjectConfig (..),
    Resources (..),
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
            service <- expectRight (deriveProjectConfigForKind ClusterService vm "/srv/demo")
            vm.dockerfile @?= hostCfg.dockerfile
            service.deploy @?= hostCfg.deploy
            vm.resources @?= hostCfg.resources
            -- The served message is forwarded down every child frame (Sprint 20.1).
            vm.message @?= hostCfg.message
            service.message @?= hostCfg.message
            contextKind (context vm) @?= VMOrchestrator
            parentChain (context vm) @?= [ContextFrame HostOrchestrator "hostbootstrap-demo"]
            topologyFrames (context vm)
                @?= [ TopologyFrame "host-orchestrator-0" "" HostProvider HostOrchestrator "host-orchestrator"
                    , TopologyFrame "vm-orchestrator-1" "host-orchestrator-0" IncusVMProvider VMOrchestrator "vm-orchestrator"
                    ]
            contextKind (context service) @?= ClusterService
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
            service <- expectRight (deriveProjectConfigForKind ClusterService vm "/srv/demo")
            commandAllowed (context hostCfg) HostOrchestratorCommand @?= True
            commandAllowed (context service) ServiceCommand @?= True
            commandAllowed (context service) HostOrchestratorCommand @?= False
            assertBool "service keeps the kubernetes capability" (KubernetesAPI `elem` capabilities (context service))
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
