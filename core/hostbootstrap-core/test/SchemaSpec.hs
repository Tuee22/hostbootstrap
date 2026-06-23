{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SchemaSpec (tests) where

import Control.Exception (SomeException, try)
import qualified Data.Text as T
import Fixture
  ( DeployConfig (..),
    ProjectConfig (..),
    Resources (..),
    decodeProjectConfigFile,
    decodeProjectConfigText,
    decodeTestConfigText,
    defaultProjectConfig,
    defaultTestConfig,
    deriveProjectConfigForKind,
    renderProjectConfig,
    renderTestConfig,
  )
import HostBootstrap.Config.Schema
  ( parseConfigRole,
    projectConfigSnapshotHash,
    renderProjectConfigSnapshotLog,
    validateProjectConfigForProject,
  )
import HostBootstrap.Context
  ( BinaryContext (..),
    Capability (..),
    CommandClass (..),
    ContextFrame (..),
    ContextKind (..),
    ProviderKind (..),
    ResourceEnvelope (..),
    TopologyFrame (..),
    commandAllowed,
  )
import HostBootstrap.DocValidator (findRepoRoot)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

validConfig :: String
validConfig = T.unpack (renderProjectConfig expected)

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
            topologyFrames =
              [ TopologyFrame "host-orchestrator-0" "" HostProvider HostOrchestrator "host-orchestrator"
              ],
            currentFrame = "host-orchestrator-0",
            runtimeWitnesses = [],
            capabilities = [HostTools, IncusProvider],
            allowedCommandClasses =
              [ EnsureCommand,
                ConfigInspectionCommand,
                ConfigGenerationCommand,
                ContextCreationCommand,
                ClusterLifecycleCommand,
                TestWorkflowCommand,
                CheckCodeCommand,
                HostOrchestratorCommand,
                ProjectCommand
              ],
            resourceEnvelope = ResourceEnvelope 4 "8GiB" "20GiB",
            childContextKinds = [VMOrchestrator, ClusterService, Daemon, OneShotJob, TestHarness]
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
      testCase "rendered test.dhall decodes back to the same TestConfig" $ do
        let tc = defaultTestConfig ["pristine-bootstrap", "all"] (Resources 6 "10GiB" "80GiB")
        decoded <- decodeTestConfigText (renderTestConfig tc)
        decoded @?= tc,
      testCase "rendered config hoists each vocabulary union into a single let" $ do
        let rendered = renderProjectConfig (defaultProjectConfig "demo" "/workspace/demo" HostOrchestrator)
        -- Each union is declared once at the top, not inlined at every use site.
        T.count "let ContextKind =" rendered @?= 1
        T.count "let ProviderKind =" rendered @?= 1
        T.count "let WitnessKind =" rendered @?= 1
        T.count "let Capability =" rendered @?= 1
        T.count "let CommandClass =" rendered @?= 1
        T.count "< HostOrchestrator" rendered @?= 1
        assertBool
          "use sites reference the hoisted binding"
          ("ContextKind.HostOrchestrator" `T.isInfixOf` rendered),
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
        parseConfigRole "image-build-container" @?= Right ImageBuildContainer
        parseConfigRole "one_shot" @?= Right OneShotJob
        parseConfigRole "unknown" @?= Left "unknown config role unknown (expected one of: host-orchestrator, vm-orchestrator, vm-project-container, image-build-container, cluster-service, daemon, one-shot-job, test-harness)",
      testCase "default role configs decode and re-render stably" $ do
        mapM_
          ( \role -> do
              let cfg = defaultProjectConfig "demo" "/workspace/demo" role
              decoded <- decodeProjectConfigText (renderProjectConfig cfg)
              decoded @?= cfg
              contextKind (context cfg) @?= role
          )
          [HostOrchestrator, VMOrchestrator, VMProjectContainer, ImageBuildContainer, ClusterService, Daemon, OneShotJob, TestHarness],
      testCase "child projections preserve project settings and narrow authority" $ do
        let host = defaultProjectConfig "demo" "/workspace/demo" HostOrchestrator
        vm <- expectRight (deriveProjectConfigForKind VMOrchestrator host "/vm/demo")
        service <- expectRight (deriveProjectConfigForKind ClusterService vm "/srv/demo")
        dockerfile vm @?= dockerfile host
        deploy service @?= deploy host
        resources vm @?= resources host
        contextKind (context vm) @?= VMOrchestrator
        parentChain (context vm) @?= [ContextFrame HostOrchestrator "demo"]
        topologyFrames (context vm)
          @?= [ TopologyFrame "host-orchestrator-0" "" HostProvider HostOrchestrator "host-orchestrator",
                TopologyFrame "vm-orchestrator-1" "host-orchestrator-0" IncusVMProvider VMOrchestrator "vm-orchestrator"
              ]
        contextKind (context service) @?= ClusterService
        parentChain (context service)
          @?= [ContextFrame HostOrchestrator "demo", ContextFrame VMOrchestrator "demo"],
      testCase "child projection rejects direct host-to-runtime-container configs" $ do
        let host = defaultProjectConfig "demo" "/workspace/demo" HostOrchestrator
        deriveProjectConfigForKind VMProjectContainer host "/workspace/demo"
          @?= Left "project config: child context VMProjectContainer is not allowed in HostOrchestrator",
      testCase "generated roles cannot authorize illegal command families" $ do
        let host = defaultProjectConfig "demo" "/workspace/demo" HostOrchestrator
            container = defaultProjectConfig "demo" "/workspace/demo" VMProjectContainer
            imageBuild = defaultProjectConfig "demo" "/workspace/demo" ImageBuildContainer
            service = defaultProjectConfig "demo" "/workspace/demo" ClusterService
            daemon = defaultProjectConfig "demo" "/workspace/demo" Daemon
        commandAllowed (context host) HostOrchestratorCommand @?= True
        commandAllowed (context container) HostOrchestratorCommand @?= False
        commandAllowed (context imageBuild) CheckCodeCommand @?= True
        commandAllowed (context imageBuild) TestWorkflowCommand @?= False
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
      T.unpack (T.replace "haReplicas = 2" "haReplicas = \"two\"" (renderProjectConfig expected))

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
      contents <- readFile path
      decoded <- decodeProjectConfigFile path
      decoded @?= expected
      T.stripEnd (T.pack contents) @?= T.stripEnd (renderProjectConfig expected)

toText :: String -> T.Text
toText = T.pack

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

expectRight :: Either String a -> IO a
expectRight result =
  case result of
    Right value -> pure value
    Left err -> assertFailure err
