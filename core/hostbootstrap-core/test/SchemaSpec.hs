{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SchemaSpec (tests) where

import Control.Exception (SomeException, try)
import qualified Data.Text as T
import HostBootstrap.Config.Schema
  ( DeployConfig (..),
    ProjectConfig (..),
    Resources (..),
    decodeProjectConfigFile,
    decodeProjectConfigText,
    defaultProjectConfig,
    deriveProjectConfigForKind,
    parseConfigRole,
    projectConfigSnapshotHash,
    renderProjectConfig,
    renderProjectConfigSnapshotLog,
    validateProjectConfigForProject,
  )
import HostBootstrap.Context
  ( BinaryContext (..),
    Capability (..),
    CommandClass (..),
    ContextFrame (..),
    ContextKind (..),
    ResourceEnvelope (..),
    commandAllowed,
  )
import HostBootstrap.DocValidator (findRepoRoot)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

validConfig :: String
validConfig =
  unlines
    [ "{ dockerfile = \"docker/demo.Dockerfile\"",
      ", resources = { cpu = 4, memory = \"8GiB\", storage = \"20GiB\" }",
      ", context =",
      "    { project = \"demo\"",
      "    , binary = \"demo\"",
      "    , sourceRoot = \"/workspace/demo\"",
      "    , contextKind = < HostOrchestrator | VMOrchestrator | VMProjectContainer | ClusterService | Daemon | OneShotJob | TestHarness >.HostOrchestrator",
      "    , roleName = \"host-orchestrator\"",
      "    , parentChain = [] : List { frameKind : < HostOrchestrator | VMOrchestrator | VMProjectContainer | ClusterService | Daemon | OneShotJob | TestHarness >, frameBinary : Text }",
      "    , capabilities = [ < HostTools | IncusProvider | DockerSocket | ContainerRuntime | KubernetesAPI | KindNetwork | DurableStore | ServicePort >.HostTools, < HostTools | IncusProvider | DockerSocket | ContainerRuntime | KubernetesAPI | KindNetwork | DurableStore | ServicePort >.IncusProvider ]",
      "    , allowedCommandClasses = [ < EnsureCommand | ConfigInspectionCommand | ConfigGenerationCommand | ContextCreationCommand | ClusterLifecycleCommand | TestWorkflowCommand | CheckCodeCommand | HostOrchestratorCommand | DaemonCommand | ServiceCommand | ProjectCommand >.EnsureCommand, < EnsureCommand | ConfigInspectionCommand | ConfigGenerationCommand | ContextCreationCommand | ClusterLifecycleCommand | TestWorkflowCommand | CheckCodeCommand | HostOrchestratorCommand | DaemonCommand | ServiceCommand | ProjectCommand >.ConfigInspectionCommand, < EnsureCommand | ConfigInspectionCommand | ConfigGenerationCommand | ContextCreationCommand | ClusterLifecycleCommand | TestWorkflowCommand | CheckCodeCommand | HostOrchestratorCommand | DaemonCommand | ServiceCommand | ProjectCommand >.ProjectCommand ]",
      "    , resourceEnvelope = { cpu = 4, memory = \"8GiB\", storage = \"20GiB\" }",
      "    , childContextKinds = [ < HostOrchestrator | VMOrchestrator | VMProjectContainer | ClusterService | Daemon | OneShotJob | TestHarness >.VMOrchestrator, < HostOrchestrator | VMOrchestrator | VMProjectContainer | ClusterService | Daemon | OneShotJob | TestHarness >.VMProjectContainer ]",
      "    }",
      ", deploy = { haReplicas = 2 }",
      "}"
    ]

expected :: ProjectConfig
expected =
  ProjectConfig
    { dockerfile = "docker/demo.Dockerfile",
      resources = Resources 4 "8GiB" "20GiB",
      context =
        BinaryContext
          { project = "demo",
            binary = "demo",
            sourceRoot = "/workspace/demo",
            contextKind = HostOrchestrator,
            roleName = "host-orchestrator",
            parentChain = [],
            capabilities = [HostTools, IncusProvider],
            allowedCommandClasses = [EnsureCommand, ConfigInspectionCommand, ProjectCommand],
            resourceEnvelope = ResourceEnvelope 4 "8GiB" "20GiB",
            childContextKinds = [VMOrchestrator, VMProjectContainer]
          },
      deploy = DeployConfig {haReplicas = 2}
    }

tests :: TestTree
tests =
  testGroup
    "SchemaSpec"
    [ testCase "decodes a valid project-local config" $ do
        decoded <- decodeProjectConfigText (toText validConfig)
        decoded @?= expected,
      testCase "rendered project-local config decodes back" $ do
        decoded <- decodeProjectConfigText (renderProjectConfig expected)
        decoded @?= expected,
      testCase "a malformed config fails with a typed error" $ do
        result <- try (decodeProjectConfigText "{ dockerfile = \"x\" }") :: IO (Either SomeException ProjectConfig)
        case result of
          Left _ -> pure ()
          Right s -> assertFailure ("expected a decode error, got " ++ show s),
      testCase "a wrong-typed field fails with a typed error" $ do
        result <-
          try (decodeProjectConfigText (toText badTypeConfig)) ::
            IO (Either SomeException ProjectConfig)
        assertBool "expected a decode error for haReplicas : Text" (isLeft result),
      testCase "decodes the canonical example.dhall fixture" decodeFixture,
      testCase "validates the runtime context against the Cabal-derived project name" $ do
        validateProjectConfigForProject "demo" expected @?= Right expected
        validateProjectConfigForProject "other" expected
          @?= Left "project config: expected project other, got demo",
      testCase "parses canonical role names and aliases" $ do
        parseConfigRole "host" @?= Right HostOrchestrator
        parseConfigRole "vm-project-container" @?= Right VMProjectContainer
        parseConfigRole "one_shot" @?= Right OneShotJob
        parseConfigRole "unknown" @?= Left "unknown config role unknown (expected one of: host-orchestrator, vm-orchestrator, vm-project-container, cluster-service, daemon, one-shot-job, test-harness)",
      testCase "default role configs decode and re-render stably" $ do
        mapM_
          ( \role -> do
              let cfg = defaultProjectConfig "demo" "/workspace/demo" role
              decoded <- decodeProjectConfigText (renderProjectConfig cfg)
              decoded @?= cfg
              contextKind (context cfg) @?= role
          )
          [HostOrchestrator, VMOrchestrator, VMProjectContainer, ClusterService, Daemon],
      testCase "child projections preserve project settings and narrow authority" $ do
        let host = defaultProjectConfig "demo" "/workspace/demo" HostOrchestrator
        vm <- expectRight (deriveProjectConfigForKind VMOrchestrator host "/vm/demo")
        service <- expectRight (deriveProjectConfigForKind ClusterService vm "/srv/demo")
        dockerfile vm @?= dockerfile host
        deploy service @?= deploy host
        resources vm @?= resources host
        contextKind (context vm) @?= VMOrchestrator
        parentChain (context vm) @?= [ContextFrame HostOrchestrator "demo"]
        contextKind (context service) @?= ClusterService
        parentChain (context service)
          @?= [ContextFrame HostOrchestrator "demo", ContextFrame VMOrchestrator "demo"],
      testCase "generated roles cannot authorize illegal command families" $ do
        let host = defaultProjectConfig "demo" "/workspace/demo" HostOrchestrator
            container = defaultProjectConfig "demo" "/workspace/demo" VMProjectContainer
            service = defaultProjectConfig "demo" "/workspace/demo" ClusterService
            daemon = defaultProjectConfig "demo" "/workspace/demo" Daemon
        commandAllowed (context host) HostOrchestratorCommand @?= True
        commandAllowed (context container) HostOrchestratorCommand @?= False
        commandAllowed (context service) ServiceCommand @?= True
        commandAllowed (context host) ServiceCommand @?= False
        commandAllowed (context container) ServiceCommand @?= False
        commandAllowed (context daemon) DaemonCommand @?= True
        commandAllowed (context host) DaemonCommand @?= False,
      testCase "daemon snapshot log includes config metadata without secret content" $ do
        let daemon = defaultProjectConfig "demo" "/workspace/demo" Daemon
            hash = projectConfigSnapshotHash "password = \"secret\""
            line = renderProjectConfigSnapshotLog "/run/demo.dhall" hash (context daemon)
        assertBool "hash is tagged" ("fnv64:" `T.isPrefixOf` hash)
        assertBool "project is logged" ("project=demo" `T.isInfixOf` line)
        assertBool "role is logged" ("roleName=daemon" `T.isInfixOf` line)
        assertBool "path is logged" ("configPath=/run/demo.dhall" `T.isInfixOf` line)
        assertBool "hash is logged" (("configHash=" <> hash) `T.isInfixOf` line)
        assertBool "config content is not logged" (not ("secret" `T.isInfixOf` line))
    ]
  where
    badTypeConfig =
      unlines
        [ "{ dockerfile = \"docker/demo.Dockerfile\"",
          ", resources = { cpu = 4, memory = \"8GiB\", storage = \"20GiB\" }",
          ", context =",
          "    { project = \"demo\"",
          "    , binary = \"demo\"",
          "    , sourceRoot = \"/workspace/demo\"",
          "    , contextKind = < HostOrchestrator | VMOrchestrator | VMProjectContainer | ClusterService | Daemon | OneShotJob | TestHarness >.HostOrchestrator",
          "    , roleName = \"host-orchestrator\"",
          "    , parentChain = [] : List { frameKind : < HostOrchestrator | VMOrchestrator | VMProjectContainer | ClusterService | Daemon | OneShotJob | TestHarness >, frameBinary : Text }",
          "    , capabilities = [] : List < HostTools | IncusProvider | DockerSocket | ContainerRuntime | KubernetesAPI | KindNetwork | DurableStore | ServicePort >",
          "    , allowedCommandClasses = [] : List < EnsureCommand | ConfigInspectionCommand | ConfigGenerationCommand | ContextCreationCommand | ClusterLifecycleCommand | TestWorkflowCommand | CheckCodeCommand | HostOrchestratorCommand | DaemonCommand | ServiceCommand | ProjectCommand >",
          "    , resourceEnvelope = { cpu = 4, memory = \"8GiB\", storage = \"20GiB\" }",
          "    , childContextKinds = [] : List < HostOrchestrator | VMOrchestrator | VMProjectContainer | ClusterService | Daemon | OneShotJob | TestHarness >",
          "    }",
          ", deploy = { haReplicas = \"two\" }",
          "}"
        ]

decodeFixture :: IO ()
decodeFixture = do
  cwd <- getCurrentDirectory
  mroot <- findRepoRoot cwd
  case mroot of
    Nothing -> assertFailure ("could not locate repo root from " ++ cwd)
    Just root -> do
      let path = root </> "core" </> "hostbootstrap-core" </> "dhall" </> "example.dhall"
      exists <- doesFileExist path
      assertBool ("fixture exists: " ++ path) exists
      decoded <- decodeProjectConfigFile path
      decoded @?= expected

toText :: String -> T.Text
toText = T.pack

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

expectRight :: Either String a -> IO a
expectRight result =
  case result of
    Right value -> pure value
    Left err -> assertFailure err
